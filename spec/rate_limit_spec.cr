# Mirror of oracle/rate_limit_expected.yml (captured from actionpack
# 8.1.4 via action_pack.cr/oracle/rate_limit_cases.rb). Same case IDs,
# same expectations. Runs the full CRails stack (routes -> controller
# -> filters -> rate limit -> cache store); 429 comes from the request
# layer rescuing ActionController::TooManyRequests, like the Rails
# oracle's ShowExceptions wrapper.
#
# All plain requests carry X-Forwarded-For: 10.0.0.1 so bucket
# identities (and cache keys) match the oracle's REMOTE_ADDR=10.0.0.1.

require "spec"
require "../src/railties_cr"

RL_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../../action_pack.cr/oracle/rate_limit_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

module Events
  class_property events = [] of Hash(String, ActiveSupport::Any)
end

ActiveSupport::Notifications.subscribe("rate_limit.action_controller") do |event|
  Events.events << event.payload
end

# --- controllers (mirroring the oracle's controllers 1:1) ---------------

class PlainController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 3, within: 60.seconds, store: STORE

  def index
    render plain: "ok"
  end
end

class ByHeaderController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 2, within: 60.seconds, store: STORE, by: :api_key

  def index
    render plain: "ok"
  end

  def api_key : String
    request.headers["X-Key"]? || "none"
  end
end

class BusyController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 1, within: 60.seconds, store: STORE, with: :too_busy

  def index
    render plain: "ok"
  end

  def too_busy
    render plain: "busy", status: 503
  end
end

class NamedController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 1, within: 60.seconds, store: STORE, name: "short"
  rate_limit to: 3, within: 60.seconds, store: STORE, name: "long"

  def index
    render plain: "ok"
  end
end

class ScopeAController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 2, within: 60.seconds, store: STORE, scope: "shared"

  def index
    render plain: "a"
  end
end

class ScopeBController < ActionController::Base
  rate_limit to: 2, within: 60.seconds, store: ScopeAController::STORE, scope: "shared"

  def index
    render plain: "b"
  end
end

class OnlyController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 2, within: 60.seconds, store: STORE, only: [:create]

  def index
    render plain: "index"
  end

  def create
    render plain: "created"
  end
end

class ShortWindowController < ActionController::Base
  STORE = ActiveSupport::Cache::MemoryStore.new
  rate_limit to: 1, within: 0.3.seconds, store: STORE

  def index
    render plain: "ok"
  end
end

class NullStoreController < ActionController::Base
  rate_limit to: 1, within: 60.seconds, store: ActiveSupport::Cache::NullStore.new

  def index
    render plain: "ok"
  end
end

# --- app + server --------------------------------------------------------

APP_RL = CRails::Application.new.tap do |app|
  app.routes.draw do
    get "/plain", to: "plain#index"
    get "/by_header", to: "by_header#index"
    get "/busy", to: "busy#index"
    get "/named", to: "named#index"
    get "/scope_a", to: "scope_a#index"
    get "/scope_b", to: "scope_b#index"
    get "/only_test", to: "only#index"
    post "/only_test", to: "only#create"
    get "/short_window", to: "short_window#index"
    get "/null_store", to: "null_store#index"
  end
end

module SpecRL
  class_property addr : Socket::IPAddress?
end

server = HTTP::Server.new { |ctx| APP_RL.call(ctx) }
SpecRL.addr = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }
sleep 50.milliseconds

def rl_req(method : String, path : String, xff : String? = "10.0.0.1", headers : Hash(String, String) = {} of String => String) : Int32
  addr = SpecRL.addr.not_nil!
  h = HTTP::Headers.new
  h["X-Forwarded-For"] = xff if xff
  headers.each { |k, v| h[k] = v }
  HTTP::Client.new(addr.address, addr.port) do |client|
    client.exec(HTTP::Request.new(method, path, headers: h)).status_code
  end
end

def rl_get(path : String, xff : String? = "10.0.0.1", headers : Hash(String, String) = {} of String => String) : Int32
  rl_req("GET", path, xff, headers)
end

def rl_post(path : String) : Int32
  rl_req("POST", path)
end

def payload_str(v : ActiveSupport::Any) : String
  case v
  when String then v
  when Nil    then ""
  else             v.to_s
  end
end

describe "rate limiting (actionpack 8.1.4 oracle)" do
  it "default_first_3_pass" do
    (1..3).map { rl_get("/plain") }.join(",").should eq RL_EXPECTED["default_first_3_pass"]
  end

  it "default_4th_is_429" do
    rl_get("/plain").to_s.should eq RL_EXPECTED["default_4th_is_429"]
  end

  it "default_5th_still_429" do
    rl_get("/plain").to_s.should eq RL_EXPECTED["default_5th_still_429"]
  end

  it "separate_ip_buckets" do
    rl_get("/plain", xff: "10.0.0.2").to_s.should eq RL_EXPECTED["separate_ip_buckets"]
  end

  it "instrument_payload_counts" do
    Events.events.select { |p| p["name"]?.to_s.empty? }
      .map { |p| payload_str(p["count"].as(ActiveSupport::Any)) }.join(",")
      .should eq RL_EXPECTED["instrument_payload_counts"]
  end

  it "instrument_cache_key" do
    payload_str(Events.events.last["cache_key"].as(ActiveSupport::Any))
      .should eq RL_EXPECTED["instrument_cache_key"]
  end

  it "instrument_payload_keys" do
    Events.events.last.keys.reject(&.==("exception")).sort.join(",")
      .should eq RL_EXPECTED["instrument_payload_keys"]
  end

  it "custom_by_header_buckets" do
    a1 = rl_get("/by_header", headers: {"X-Key" => "key-a"})
    a2 = rl_get("/by_header", headers: {"X-Key" => "key-a"})
    b1 = rl_get("/by_header", headers: {"X-Key" => "key-b"})
    [a1, a2, b1].join(",").should eq RL_EXPECTED["custom_by_header_buckets"]
  end

  it "custom_by_429_cache_key" do
    rl_get("/by_header", headers: {"X-Key" => "key-a"}) # 3rd for key-a -> 429
    payload_str(Events.events.select { |p| payload_str(p["cache_key"].as(ActiveSupport::Any)).includes?("key-a") }
      .last["cache_key"].as(ActiveSupport::Any))
      .should eq RL_EXPECTED["custom_by_429_cache_key"]
  end

  it "with_symbol_handler" do
    rl_get("/busy") # 1st: ok
    rl_get("/busy").to_s.should eq RL_EXPECTED["with_symbol_handler"] # 2nd: handler
  end

  it "named_two_limits" do
    n1 = rl_get("/named")
    n2 = rl_get("/named") # 2nd: "short" (to=1) exceeded -> 429
    [n1, n2].join(",").should eq RL_EXPECTED["named_two_limits"]
  end

  it "named_limits_share_request" do
    Events.events.select { |p| !p["name"]?.to_s.empty? }
      .group_by { |p| payload_str(p["name"].as(ActiveSupport::Any)) }
      .map { |name, ps| "#{name}:#{ps.map { |p| payload_str(p["count"].as(ActiveSupport::Any)) }.join(",")}" }
      .sort.join(" ").should eq RL_EXPECTED["named_limits_share_request"]
  end

  it "scope_shared_between_controllers" do
    a1 = rl_get("/scope_a")
    a2 = rl_get("/scope_a")
    a3 = rl_get("/scope_a") # over shared limit
    b1 = rl_get("/scope_b") # same shared bucket -> 429
    [a1, a2, a3, b1].join(",").should eq RL_EXPECTED["scope_shared_between_controllers"]
  end

  it "only_option_index_unlimited" do
    (1..4).map { rl_get("/only_test") }.join(",")
      .should eq RL_EXPECTED["only_option_index_unlimited"]
  end

  it "only_option_create_limited" do
    c1 = rl_post("/only_test")
    c2 = rl_post("/only_test")
    c3 = rl_post("/only_test") # 3rd -> 429
    [c1, c2, c3].join(",").should eq RL_EXPECTED["only_option_create_limited"]
  end

  it "expires_window_semantics" do
    ShortWindowController::STORE.clear
    s1 = rl_get("/short_window")
    s2 = rl_get("/short_window")
    sleep(0.5.seconds) # > within since first request
    s3 = rl_get("/short_window")
    [s1, s2, s3].join(",").should eq RL_EXPECTED["expires_window_semantics"]
  end

  it "null_store_no_limit" do
    (1..4).map { rl_get("/null_store") }.join(",")
      .should eq RL_EXPECTED["null_store_no_limit"]
  end
end

# Documented deviations (also in src/rate_limiting.cr):
# - by:/with: take a controller method name (Symbol); the gem accepts
#   arbitrary lambdas via instance_exec.
# - instrument payload: "request" is the path (not a Request object),
#   "within" is a String.
