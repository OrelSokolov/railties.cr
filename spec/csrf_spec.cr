# Mirror of action_pack.cr/oracle/csrf_expected.yml (captured from
# actionpack 8.1.4 via action_pack.cr/oracle/csrf_cases.rb). Same case
# IDs, same expectations. Runs the full CRails stack (routes ->
# controller -> CSRF filter -> session cookie store); 422 comes from
# the request layer rescuing ActionController::InvalidAuthenticityToken
# / InvalidCrossOriginRequest, like the Rails oracle's ShowExceptions.
#
# Cookie jars are real: tokens fetched on one connection are replayed
# on the next through the Set-Cookie/Cookie round trip, exercising the
# full masked-token lifecycle.

require "spec"
require "../src/railties_cr"

CSRF_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../../action_pack.cr/oracle/csrf_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

# --- controllers (mirroring the oracle's controllers 1:1) ---------------

class CsExceptionController < ActionController::Base
  protect_from_forgery with: :exception

  def token
    render plain: form_authenticity_token
  end

  def create
    render plain: "created"
  end
end

class CsNullSessionController < ActionController::Base
  protect_from_forgery with: :null_session

  def set_mark
    session["mark"] = "v"
    render plain: "set"
  end

  def show_mark
    render plain: (session["mark"]? || "").to_s
  end
end

class CsResetSessionController < ActionController::Base
  protect_from_forgery with: :reset_session

  def set_mark
    session["mark"] = "v"
    render plain: "set"
  end

  def show_mark
    render plain: (session["mark"]? || "").to_s
  end
end

class CsSkippedController < ActionController::Base
  protect_from_forgery with: :exception
  skip_forgery_protection

  def create
    render plain: "created"
  end
end

class CsExceptController < ActionController::Base
  protect_from_forgery with: :exception, except: :create

  def create
    render plain: "created"
  end

  def update
    render plain: "updated"
  end
end

class CsPerFormController < ActionController::Base
  protect_from_forgery with: :exception

  def form_token
    render plain: form_authenticity_token(action: "/cf_create", method: "post")
  end

  def global_token
    render plain: form_authenticity_token
  end

  def cf_create
    render plain: "created"
  end

  def other_create
    render plain: "other"
  end
end

class CsOriginController < ActionController::Base
  protect_from_forgery with: :exception

  def token
    render plain: form_authenticity_token
  end

  def create
    render plain: "created"
  end
end

class CsAllowOffController < ActionController::Base
  protect_from_forgery with: :exception

  def create
    render plain: "created"
  end
end

class CsJsController < ActionController::Base
  protect_from_forgery with: :exception

  def script
    render plain: "// js", content_type: "text/javascript"
  end
end

# --- app + server --------------------------------------------------------

APP_CSRF = CRails::Application.new.tap do |app|
  app.routes.draw do
    get "/token", to: "cs_exception#token"
    {% for verb in %w(post put patch delete) %}
      {{verb.id}} "/cs_create", to: "cs_exception#create"
    {% end %}
    get "/null_set", to: "cs_null_session#set_mark"
    get "/null_show", to: "cs_null_session#show_mark"
    post "/null_show", to: "cs_null_session#show_mark"
    get "/reset_set", to: "cs_reset_session#set_mark"
    get "/reset_show", to: "cs_reset_session#show_mark"
    post "/reset_show", to: "cs_reset_session#show_mark"
    post "/skip_create", to: "cs_skipped#create"
    post "/except_create", to: "cs_except#create"
    post "/except_update", to: "cs_except#update"
    get "/form_token", to: "cs_per_form#form_token"
    get "/global_token", to: "cs_per_form#global_token"
    post "/cf_create", to: "cs_per_form#cf_create"
    post "/other_create", to: "cs_per_form#other_create"
    get "/origin_token", to: "cs_origin#token"
    post "/origin_create", to: "cs_origin#create"
    post "/allow_create", to: "cs_allow_off#create"
    get "/script", to: "cs_js#script"
  end
end

module SpecCsrf
  class_property addr : Socket::IPAddress?
end

csrf_server = HTTP::Server.new { |ctx| APP_CSRF.call(ctx) }
SpecCsrf.addr = csrf_server.bind_tcp("127.0.0.1", 0)
spawn { csrf_server.listen }
sleep 50.milliseconds

# Cookie jar across requests (a "browser").
class CsrfJar
  property cookies = {} of String => String

  def absorb(response : HTTP::Client::Response) : Nil
    if cookies_header = response.headers.get?("Set-Cookie")
      cookies_header.each do |c|
        k, v = c.split('=', 2)
        v = v.split(';').first.to_s
        if v.empty?
          cookies.delete(k)
        else
          cookies[k] = v
        end
      end
    end
  end

  def apply(request : HTTP::Request) : Nil
    return if cookies.empty?
    request.headers["Cookie"] = cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
  end
end

def csrf_req(method : String, path : String, jar : CsrfJar,
             params : Hash(String, String)? = nil,
             headers : Hash(String, String) = {} of String => String) : HTTP::Client::Response
  addr = SpecCsrf.addr.not_nil!
  h = HTTP::Headers.new
  headers.each { |k, v| h[k] = v }
  request = HTTP::Request.new(method, path, headers: h)
  jar.apply(request)
  if params
    request.headers["Content-Type"] = "application/x-www-form-urlencoded"
    request.body = URI::Params.encode(params)
  end
  response = HTTP::Client.new(addr.address, addr.port) do |client|
    client.exec(request)
  end
  jar.absorb(response)
  response
end

def csrf_body(response : HTTP::Client::Response) : String
  response.body.to_s
end

def unmask64(token : String) : Bytes
  decoded = Base64.decode(token)
  pad = decoded[0, 32]
  enc = decoded[32, 32]
  out = Bytes.new(32)
  32.times { |i| out[i] = pad[i] ^ enc[i] }
  out
end

describe "CSRF protection (actionpack 8.1.4 oracle)" do
  it "exc_get_ok" do
    csrf_req("GET", "/token", CsrfJar.new).status_code.to_s
      .should eq CSRF_EXPECTED["exc_get_ok"]
  end

  it "exc_post_no_token_422" do
    csrf_req("POST", "/cs_create", CsrfJar.new).status_code.to_s
      .should eq CSRF_EXPECTED["exc_post_no_token_422"]
  end

  it "exc_post_garbage_token_422" do
    csrf_req("POST", "/cs_create", CsrfJar.new,
      params: {"authenticity_token" => "garbage!!!"}).status_code.to_s
      .should eq CSRF_EXPECTED["exc_post_garbage_token_422"]
  end

  it "exc_post_empty_token_422" do
    csrf_req("POST", "/cs_create", CsrfJar.new,
      params: {"authenticity_token" => ""}).status_code.to_s
      .should eq CSRF_EXPECTED["exc_post_empty_token_422"]
  end

  it "exc_post_valid_global_token_ok" do
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/token", jar))
    csrf_req("POST", "/cs_create", jar, params: {"authenticity_token" => token}).status_code.to_s
      .should eq CSRF_EXPECTED["exc_post_valid_global_token_ok"]
  end

  it "exc_post_header_token_ok" do
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/token", jar))
    csrf_req("POST", "/cs_create", jar, headers: {"X-CSRF-Token" => token}).status_code.to_s
      .should eq CSRF_EXPECTED["exc_post_header_token_ok"]
  end

  it "exc_token_rotates" do
    jar = CsrfJar.new
    t1 = csrf_body(csrf_req("GET", "/token", jar))
    t2 = csrf_body(csrf_req("GET", "/token", jar))
    (t1 != t2).to_s.should eq CSRF_EXPECTED["exc_token_rotates"]
  end

  it "exc_token_reusable" do
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/token", jar))
    s1 = csrf_req("POST", "/cs_create", jar, params: {"authenticity_token" => token}).status_code
    s2 = csrf_req("POST", "/cs_create", jar, params: {"authenticity_token" => token}).status_code
    [s1, s2].join(",").should eq CSRF_EXPECTED["exc_token_reusable"]
  end

  it "exc_cross_session_token_422" do
    jar_a = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/token", jar_a))
    jar_b = CsrfJar.new # fresh browser: different session
    csrf_req("POST", "/cs_create", jar_b, params: {"authenticity_token" => token}).status_code.to_s
      .should eq CSRF_EXPECTED["exc_cross_session_token_422"]
  end

  it "exc_put_patch_delete_no_token" do
    jar = CsrfJar.new
    [csrf_req("PUT", "/cs_create", jar).status_code,
     csrf_req("PATCH", "/cs_create", jar).status_code,
     csrf_req("DELETE", "/cs_create", jar).status_code].join(",")
      .should eq CSRF_EXPECTED["exc_put_patch_delete_no_token"]
  end

  it "exc_unmasked_token_rejected" do
    jar = CsrfJar.new
    masked = csrf_body(csrf_req("GET", "/token", jar))
    raw = Base64.urlsafe_encode(unmask64(masked), padding: false)
    csrf_req("POST", "/cs_create", jar, params: {"authenticity_token" => raw}).status_code.to_s
      .should eq CSRF_EXPECTED["exc_unmasked_token_rejected"]
  end

  it "exc_raise_class" do
    # класс исключения — как в оракуле; railties-лестница маппит его в 422
    io = IO::Memory.new
    ctx = HTTP::Server::Context.new(
      HTTP::Request.new("POST", "/cs_create"), HTTP::Server::Response.new(io))
    ctrl = CsExceptionController.new(ctx)
    ctrl.__set_params({} of String => String)
    expect_raises(ActionController::InvalidAuthenticityToken) { ctrl.__run_action("create") }
    ("raise:" + "ActionController::InvalidAuthenticityToken").should eq CSRF_EXPECTED["exc_raise_class"]
  end

  it "null_post_no_token_200" do
    csrf_req("POST", "/null_show", CsrfJar.new).status_code.to_s
      .should eq CSRF_EXPECTED["null_post_no_token_200"]
  end

  it "null_session_emptied_during_request" do
    jar = CsrfJar.new
    csrf_req("GET", "/null_set", jar)                       # session["mark"] = "v"
    body = csrf_body(csrf_req("POST", "/null_show", jar))   # unverified POST
    body.should eq CSRF_EXPECTED["null_session_emptied_during_request"]
  end

  it "null_session_not_reset_after" do
    jar = CsrfJar.new
    csrf_req("GET", "/null_set", jar)
    csrf_req("POST", "/null_show", jar)
    csrf_body(csrf_req("GET", "/null_show", jar)).should eq CSRF_EXPECTED["null_session_not_reset_after"]
  end

  it "reset_session_emptied_permanently" do
    jar = CsrfJar.new
    csrf_req("GET", "/reset_set", jar)
    during = csrf_body(csrf_req("POST", "/reset_show", jar))
    after = csrf_body(csrf_req("GET", "/reset_show", jar))
    [during, after].join(",").should eq CSRF_EXPECTED["reset_session_emptied_permanently"]
  end

  it "skip_forgery_protection_post_ok" do
    csrf_req("POST", "/skip_create", CsrfJar.new).status_code.to_s
      .should eq CSRF_EXPECTED["skip_forgery_protection_post_ok"]
  end

  it "except_create_post_ok_update_422" do
    jar = CsrfJar.new
    [csrf_req("POST", "/except_create", jar).status_code,
     csrf_req("POST", "/except_update", jar).status_code].join(",")
      .should eq CSRF_EXPECTED["except_create_post_ok_update_422"]
  end

  it "per_form_valid_token_ok" do
    # Deviation vs the gem: per_form_csrf_tokens is a global config in
    # the Crystal port (config.action_controller.*), not a per-class
    # setter — flipped here, restored after.
    old = ActionController::RequestForgeryProtection.per_form_csrf_tokens
    ActionController::RequestForgeryProtection.per_form_csrf_tokens = true
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/form_token", jar))
    status = csrf_req("POST", "/cf_create", jar, params: {"authenticity_token" => token}).status_code
    ActionController::RequestForgeryProtection.per_form_csrf_tokens = old
    status.to_s.should eq CSRF_EXPECTED["per_form_valid_token_ok"]
  end

  it "per_form_wrong_action_422" do
    old = ActionController::RequestForgeryProtection.per_form_csrf_tokens
    ActionController::RequestForgeryProtection.per_form_csrf_tokens = true
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/form_token", jar)) # bound to /cf_create
    status = csrf_req("POST", "/other_create", jar, params: {"authenticity_token" => token}).status_code
    ActionController::RequestForgeryProtection.per_form_csrf_tokens = old
    status.to_s.should eq CSRF_EXPECTED["per_form_wrong_action_422"]
  end

  it "per_form_global_token_ok" do
    old = ActionController::RequestForgeryProtection.per_form_csrf_tokens
    ActionController::RequestForgeryProtection.per_form_csrf_tokens = true
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/global_token", jar))
    status = csrf_req("POST", "/cf_create", jar, params: {"authenticity_token" => token}).status_code
    ActionController::RequestForgeryProtection.per_form_csrf_tokens = old
    status.to_s.should eq CSRF_EXPECTED["per_form_global_token_ok"]
  end

  it "origin_bad_422" do
    old = ActionController::RequestForgeryProtection.forgery_protection_origin_check
    ActionController::RequestForgeryProtection.forgery_protection_origin_check = true
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/origin_token", jar))
    status = csrf_req("POST", "/origin_create", jar,
      params: {"authenticity_token" => token}, headers: {"Origin" => "http://evil.com"}).status_code
    ActionController::RequestForgeryProtection.forgery_protection_origin_check = old
    status.to_s.should eq CSRF_EXPECTED["origin_bad_422"]
  end

  it "origin_matching_ok" do
    old = ActionController::RequestForgeryProtection.forgery_protection_origin_check
    ActionController::RequestForgeryProtection.forgery_protection_origin_check = true
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/origin_token", jar))
    addr = SpecCsrf.addr.not_nil!
    status = csrf_req("POST", "/origin_create", jar,
      params: {"authenticity_token" => token}, headers: {"Origin" => "http://#{addr}"}).status_code
    ActionController::RequestForgeryProtection.forgery_protection_origin_check = old
    status.to_s.should eq CSRF_EXPECTED["origin_matching_ok"]
  end

  it "origin_absent_ok" do
    old = ActionController::RequestForgeryProtection.forgery_protection_origin_check
    ActionController::RequestForgeryProtection.forgery_protection_origin_check = true
    jar = CsrfJar.new
    token = csrf_body(csrf_req("GET", "/origin_token", jar))
    status = csrf_req("POST", "/origin_create", jar, params: {"authenticity_token" => token}).status_code
    ActionController::RequestForgeryProtection.forgery_protection_origin_check = old
    status.to_s.should eq CSRF_EXPECTED["origin_absent_ok"]
  end

  it "allow_off_post_ok" do
    old = ActionController::RequestForgeryProtection.allow_forgery_protection
    ActionController::RequestForgeryProtection.allow_forgery_protection = false
    status = csrf_req("POST", "/allow_create", CsrfJar.new).status_code
    ActionController::RequestForgeryProtection.allow_forgery_protection = old
    status.to_s.should eq CSRF_EXPECTED["allow_off_post_ok"]
  end

  it "js_non_xhr_422" do
    csrf_req("GET", "/script", CsrfJar.new).status_code.to_s
      .should eq CSRF_EXPECTED["js_non_xhr_422"]
  end

  it "js_xhr_ok" do
    csrf_req("GET", "/script", CsrfJar.new,
      headers: {"X-Requested-With" => "XMLHttpRequest"}).status_code.to_s
      .should eq CSRF_EXPECTED["js_xhr_ok"]
  end

  it "js_cross_origin_raise_class" do
    io = IO::Memory.new
    ctx = HTTP::Server::Context.new(
      HTTP::Request.new("GET", "/script"), HTTP::Server::Response.new(io))
    ctrl = CsJsController.new(ctx)
    ctrl.__set_params({} of String => String)
    expect_raises(ActionController::InvalidCrossOriginRequest) { ctrl.__run_action("script") }
    ("raise:" + "ActionController::InvalidCrossOriginRequest").should eq CSRF_EXPECTED["js_cross_origin_raise_class"]
  end
end

# Documented deviations (also in src/request_forgery_protection.cr):
# - per_form_csrf_tokens / forgery_protection_origin_check /
#   allow_forgery_protection are global config (config.action_controller.*),
#   the gem also has per-class setters.
# - form_options for per-form tokens: named args action:/method:, not a hash.
# - form_authenticity_token(form_options: {action:, method:}) -> positional
#   named args (Crystal has no hash-with-symbol-keys literals).
