# Oracle spec: the Crystal port must reproduce
# oracle/host_authorization_expected.yml (captured from rails 8.1.4 via
# oracle/host_authorization_cases.rb). Same case IDs, same expectations,
# no edits on either side. Known deviations are asserted explicitly with
# (deviation) markers and listed at the bottom of this file.
#
# The oracle requests hit GET /users/sign_in of a devise app; here the
# same path renders a plain 200 through a real controller, so the
# allowed-status and Location cases stay byte-identical.

require "spec"
require "../src/railties_cr"

HA_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/host_authorization_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

HA_DEV_HOSTS = [".localhost", ".test",
                CRails::Middleware::IPCidr.new("0.0.0.0/0"),
                CRails::Middleware::IPCidr.new("::/0")] of CRails::Middleware::HostEntry

class HaSignInController < ActionController::Base
  def sign_in
    render plain: "sign in page"
  end
end

HA_APP = CRails::Application.new.tap do |app|
  app.routes.draw do
    get "/users/sign_in", to: "ha_sign_in#sign_in"
  end
end

module SpecHa
  class_property addr : Socket::IPAddress?
end

ha_server = HTTP::Server.new { |ctx| HA_APP.call(ctx) }
SpecHa.addr = ha_server.bind_tcp("127.0.0.1", 0)
spawn { ha_server.listen }
sleep 50.milliseconds

def ha_req(method : String, path : String, host : String? = nil,
           extra : Hash(String, String) = {} of String => String)
  req = HTTP::Request.new(method, path)
  req.headers["Host"] = host if host
  extra.each { |k, v| req.headers[k] = v }
  addr = SpecHa.addr.not_nil!
  HTTP::Client.new(addr.address, addr.port) { |c| c.exec(req) }
end

# Spec default: development (dev hosts + debug blocked-host page, like
# the oracle's dev app). Saved/restored around the non-local stage.
HA_ORIG_ENV = CRails.env

describe "host authorization permissions (rails 8.1.4 oracle)" do
  it "ha_perm_exact" do
    CRails::Middleware::Permissions.new(["example.com"]).allows?("example.com").inspect
      .should eq HA_EXPECTED["ha_perm_exact"]
  end

  it "ha_perm_exact_port" do
    CRails::Middleware::Permissions.new(["example.com"]).allows?("example.com:3000").inspect
      .should eq HA_EXPECTED["ha_perm_exact_port"]
  end

  it "ha_perm_exact_subdomain" do
    CRails::Middleware::Permissions.new(["example.com"]).allows?("www.example.com").inspect
      .should eq HA_EXPECTED["ha_perm_exact_subdomain"]
  end

  it "ha_perm_exact_case_insensitive" do
    CRails::Middleware::Permissions.new(["example.com"]).allows?("EXAMPLE.COM").inspect
      .should eq HA_EXPECTED["ha_perm_exact_case_insensitive"]
  end

  it "ha_perm_exact_other" do
    CRails::Middleware::Permissions.new(["example.com"]).allows?("example.org").inspect
      .should eq HA_EXPECTED["ha_perm_exact_other"]
  end

  it "ha_perm_dot_root" do
    CRails::Middleware::Permissions.new([".example.com"]).allows?("example.com").inspect
      .should eq HA_EXPECTED["ha_perm_dot_root"]
  end

  it "ha_perm_dot_subdomain" do
    CRails::Middleware::Permissions.new([".example.com"]).allows?("sub.example.com").inspect
      .should eq HA_EXPECTED["ha_perm_dot_subdomain"]
  end

  it "ha_perm_dot_port" do
    CRails::Middleware::Permissions.new([".example.com"]).allows?("example.com:8080").inspect
      .should eq HA_EXPECTED["ha_perm_dot_port"]
  end

  it "ha_perm_dot_partial" do
    CRails::Middleware::Permissions.new([".example.com"]).allows?("subexample.com").inspect
      .should eq HA_EXPECTED["ha_perm_dot_partial"]
  end

  it "ha_perm_dot_double_subdomain" do
    # the gem allows at most ONE subdomain label for ".dot" entries
    CRails::Middleware::Permissions.new([".example.com"]).allows?("a.b.example.com").inspect
      .should eq HA_EXPECTED["ha_perm_dot_double_subdomain"]
  end

  it "ha_perm_port_in_entry" do
    # a port in the entry becomes part of the pattern (no optional port)
    CRails::Middleware::Permissions.new(["example.com:3000"]).allows?("example.com").inspect
      .should eq HA_EXPECTED["ha_perm_port_in_entry"]
  end

  it "ha_perm_port_in_entry_other_port" do
    CRails::Middleware::Permissions.new(["example.com:3000"]).allows?("example.com:80").inspect
      .should eq HA_EXPECTED["ha_perm_port_in_entry_other_port"]
  end

  it "ha_perm_regexp_anchored" do
    CRails::Middleware::Permissions.new([/\Awww\.example\.com\z/]).allows?("www.example.com").inspect
      .should eq HA_EXPECTED["ha_perm_regexp_anchored"]
  end

  it "ha_perm_regexp_anchored_port" do
    # (quirk) a fully anchored user regexp never allows a port suffix
    CRails::Middleware::Permissions.new([/\Awww\.example\.com\z/]).allows?("www.example.com:3000").inspect
      .should eq HA_EXPECTED["ha_perm_regexp_anchored_port"]
  end

  it "ha_perm_regexp_partial_anchor" do
    CRails::Middleware::Permissions.new([/^.*\.example\.com$/]).allows?("www.example.com").inspect
      .should eq HA_EXPECTED["ha_perm_regexp_partial_anchor"]
  end

  it "ha_perm_regexp_partial_anchor_port" do
    # (quirk) the $ anchor blocks the port suffix
    CRails::Middleware::Permissions.new([/^.*\.example\.com$/]).allows?("www.example.com:3000").inspect
      .should eq HA_EXPECTED["ha_perm_regexp_partial_anchor_port"]
  end

  it "ha_perm_regexp_dev_sublocal" do
    CRails::Middleware::Permissions.new([/^.+\.localhost$/]).allows?("a.localhost").inspect
      .should eq HA_EXPECTED["ha_perm_regexp_dev_sublocal"]
  end

  it "ha_perm_cidr_v4_in" do
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("192.168.0.0/16")])
      .allows?("192.168.1.1").inspect.should eq HA_EXPECTED["ha_perm_cidr_v4_in"]
  end

  it "ha_perm_cidr_v4_in_port" do
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("192.168.0.0/16")])
      .allows?("192.168.1.1:8080").inspect.should eq HA_EXPECTED["ha_perm_cidr_v4_in_port"]
  end

  it "ha_perm_cidr_v4_out" do
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("192.168.0.0/16")])
      .allows?("192.169.0.1").inspect.should eq HA_EXPECTED["ha_perm_cidr_v4_out"]
  end

  it "ha_perm_cidr_v4_hostname" do
    # IPAddr#=== raises on hostnames -> treated as blocked
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("192.168.0.0/16")])
      .allows?("example.com").inspect.should eq HA_EXPECTED["ha_perm_cidr_v4_hostname"]
  end

  it "ha_perm_cidr_v4_localhost" do
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("192.168.0.0/16")])
      .allows?("localhost").inspect.should eq HA_EXPECTED["ha_perm_cidr_v4_localhost"]
  end

  it "ha_perm_cidr_any_v6" do
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("::/0")])
      .allows?("::1").inspect.should eq HA_EXPECTED["ha_perm_cidr_any_v6"]
  end

  it "ha_perm_cidr_any_v6_port" do
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("::/0")])
      .allows?("[::1]:3000").inspect.should eq HA_EXPECTED["ha_perm_cidr_any_v6_port"]
  end

  it "ha_perm_cidr_any_v6_bare_port" do
    # (quirk) "::1:3000" parses as a valid IPv6 literal, port included
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("::/0")])
      .allows?("::1:3000").inspect.should eq HA_EXPECTED["ha_perm_cidr_any_v6_bare_port"]
  end

  it "ha_perm_cidr_single_v6" do
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("::1")])
      .allows?("[::1]:8080").inspect.should eq HA_EXPECTED["ha_perm_cidr_single_v6"]
  end

  it "ha_perm_cidr_single_v6_out" do
    CRails::Middleware::Permissions.new([CRails::Middleware::IPCidr.new("::1")])
      .allows?("::2").inspect.should eq HA_EXPECTED["ha_perm_cidr_single_v6_out"]
  end

  it "ha_perm_empty" do
    CRails::Middleware::Permissions.new([] of CRails::Middleware::HostEntry)
      .allows?("evil.com").inspect.should eq HA_EXPECTED["ha_perm_empty"]
  end

  it "ha_perm_multi_second" do
    CRails::Middleware::Permissions.new(["api.example.com", ".example.com"])
      .allows?("sub.example.com").inspect.should eq HA_EXPECTED["ha_perm_multi_second"]
  end

  it "ha_perm_multi_none" do
    CRails::Middleware::Permissions.new(["api.example.com", ".example.com"])
      .allows?("www.api.example.com").inspect.should eq HA_EXPECTED["ha_perm_multi_none"]
  end

  it "ha_perm_empty_predicate" do
    CRails::Middleware::Permissions.new([] of CRails::Middleware::HostEntry)
      .empty?.inspect.should eq HA_EXPECTED["ha_perm_empty_predicate"]
  end
end

describe "host authorization http (rails 8.1.4 oracle)" do
  before_each do
    CRails.env = CRails::Env::Development
    HA_APP.config.hosts = HA_DEV_HOSTS.dup
    HA_APP.config.host_authorization_exclude = nil
    HA_APP.config.host_authorization_response_app = nil
  end

  after_each do
    CRails.env = HA_ORIG_ENV
  end

  # --- development default hosts (.localhost/.test + any IP) -----------
  it "ha_dev_localhost_status" do
    ha_req("GET", "/users/sign_in", "localhost").status_code.to_s
      .should eq HA_EXPECTED["ha_dev_localhost_status"]
  end

  it "ha_dev_localhost_port_status" do
    ha_req("GET", "/users/sign_in", "localhost:3000").status_code.to_s
      .should eq HA_EXPECTED["ha_dev_localhost_port_status"]
  end

  it "ha_dev_sub_localhost_status" do
    ha_req("GET", "/users/sign_in", "sub.localhost").status_code.to_s
      .should eq HA_EXPECTED["ha_dev_sub_localhost_status"]
  end

  it "ha_dev_ip_status" do
    ha_req("GET", "/users/sign_in", "127.0.0.1").status_code.to_s
      .should eq HA_EXPECTED["ha_dev_ip_status"]
  end

  it "ha_dev_test_tld_status" do
    ha_req("GET", "/users/sign_in", "testhost.test").status_code.to_s
      .should eq HA_EXPECTED["ha_dev_test_tld_status"]
  end

  it "ha_dev_blocked" do
    r = ha_req("GET", "/users/sign_in", "evil.com")
    r.status_code.to_s.should eq HA_EXPECTED["ha_dev_blocked_status"]
    r.headers["Content-Type"].inspect.should eq HA_EXPECTED["ha_dev_blocked_content_type"]
    body = r.body || ""
    body.empty?.inspect.should eq HA_EXPECTED["ha_dev_blocked_body_empty"]
    body.includes?("<h1>Blocked hosts: evil.com</h1>").inspect
      .should eq HA_EXPECTED["ha_dev_blocked_body_has_heading"]
    body.includes?("To allow requests to these hosts").inspect
      .should eq HA_EXPECTED["ha_dev_blocked_body_has_hint"]
    body.includes?(%(config.hosts &lt;&lt; "evil.com")).inspect
      .should eq HA_EXPECTED["ha_dev_blocked_body_has_config_hint"]
    body.includes?("https://guides.rubyonrails.org/configuring.html#actiondispatch-hostauthorization").inspect
      .should eq HA_EXPECTED["ha_dev_blocked_body_has_docs_link"]
  end

  it "ha_dev_blocked_xhr" do
    r = ha_req("GET", "/users/sign_in", "evil.com",
      {"X-Requested-With" => "XMLHttpRequest"})
    r.status_code.to_s.should eq HA_EXPECTED["ha_dev_blocked_xhr_status"]
    r.headers["Content-Type"].inspect.should eq HA_EXPECTED["ha_dev_blocked_xhr_content_type"]
  end

  it "ha_dev_forwarded_blocked_status" do
    ha_req("GET", "/users/sign_in", "localhost",
      {"X-Forwarded-Host" => "evil.com"}).status_code.to_s
      .should eq HA_EXPECTED["ha_dev_forwarded_blocked_status"]
  end

  it "ha_dev_forwarded_chain_blocked_status" do
    ha_req("GET", "/users/sign_in", "localhost",
      {"X-Forwarded-Host" => "localhost, evil.com"}).status_code.to_s
      .should eq HA_EXPECTED["ha_dev_forwarded_chain_blocked_status"]
  end

  it "ha_dev_forwarded_ok_status" do
    ha_req("GET", "/users/sign_in", "localhost",
      {"X-Forwarded-Host" => "sub.localhost"}).status_code.to_s
      .should eq HA_EXPECTED["ha_dev_forwarded_ok_status"]
  end

  it "ha_dev_origin_blocked_even_with_ok_forwarded" do
    ha_req("GET", "/users/sign_in", "evil.com",
      {"X-Forwarded-Host" => "localhost"}).status_code.to_s
      .should eq HA_EXPECTED["ha_dev_origin_blocked_even_with_ok_forwarded"]
  end

  it "ha_dev_two_blocked_hosts_heading" do
    r = ha_req("GET", "/users/sign_in", "evil.com",
      {"X-Forwarded-Host" => "bad.net"})
    (r.body || "").includes?("<h1>Blocked hosts: evil.com, bad.net</h1>").inspect
      .should eq HA_EXPECTED["ha_dev_two_blocked_hosts_heading"]
  end

  # --- consider_all_requests_local = false: empty body ------------------
  it "ha_nonlocal" do
    # (deviation) the gem keys the debug body off
    # action_dispatch.show_detailed_exceptions (consider_all_requests_
    # local); CRails uses CRails.env.development?
    CRails.env = CRails::Env::Production
    r = ha_req("GET", "/users/sign_in", "evil.com")
    r.status_code.to_s.should eq HA_EXPECTED["ha_nonlocal_status"]
    (r.body || "").empty?.inspect.should eq HA_EXPECTED["ha_nonlocal_body_empty"]
    r.headers["Content-Length"]?.inspect.should eq HA_EXPECTED["ha_nonlocal_content_length"]
    r.headers["Content-Type"].inspect.should eq HA_EXPECTED["ha_nonlocal_content_type"]
  end

  # --- custom hosts ------------------------------------------------------
  it "ha_custom" do
    HA_APP.config.hosts = ["example.com", ".dev.example.com"] of CRails::Middleware::HostEntry
    ha_req("GET", "/users/sign_in", "example.com").status_code.to_s
      .should eq HA_EXPECTED["ha_custom_exact_status"]
    ha_req("GET", "/users/sign_in", "www.example.com").status_code.to_s
      .should eq HA_EXPECTED["ha_custom_exact_subdomain_blocked"]
    ha_req("GET", "/users/sign_in", "sub.dev.example.com").status_code.to_s
      .should eq HA_EXPECTED["ha_custom_dot_subdomain_status"]
    ha_req("GET", "/users/sign_in", "dev.example.com").status_code.to_s
      .should eq HA_EXPECTED["ha_custom_dot_root_status"]
    ha_req("GET", "/users/sign_in", "dev.example.org").status_code.to_s
      .should eq HA_EXPECTED["ha_custom_dot_other_blocked"]
  end

  # --- exclude ------------------------------------------------------------
  it "ha_exclude" do
    HA_APP.config.hosts = ["example.com"] of CRails::Middleware::HostEntry
    HA_APP.config.host_authorization_exclude = ->(context : HTTP::Server::Context) do
      context.request.path == "/healthcheck"
    end
    ha_req("GET", "/healthcheck", "evil.com").status_code.to_s
      .should eq HA_EXPECTED["ha_exclude_path_status"]
    ha_req("GET", "/users/sign_in", "evil.com").status_code.to_s
      .should eq HA_EXPECTED["ha_exclude_other_still_blocked"]
  end

  # --- empty hosts: everything allowed ------------------------------------
  it "ha_empty_hosts_status" do
    HA_APP.config.hosts = [] of CRails::Middleware::HostEntry
    ha_req("GET", "/users/sign_in", "evil.com").status_code.to_s
      .should eq HA_EXPECTED["ha_empty_hosts_status"]
  end

  # --- custom response app ------------------------------------------------
  it "ha_response_app" do
    # (deviation) the response app is a Proc writing the context, not a
    # Rack triple
    HA_APP.config.hosts = ["example.com"] of CRails::Middleware::HostEntry
    HA_APP.config.host_authorization_response_app = ->(context : HTTP::Server::Context) do
      context.response.status_code = 418
      context.response.headers["Content-Type"] = "text/plain"
      context.response.print "teapot"
    end
    r = ha_req("GET", "/users/sign_in", "evil.com")
    r.status_code.to_s.should eq HA_EXPECTED["ha_response_app_status"]
    r.headers["Content-Type"].inspect.should eq HA_EXPECTED["ha_response_app_content_type"]
    (r.body || "").inspect.should eq HA_EXPECTED["ha_response_app_body"]
  end
end

# Known deviations from the rails 8.1.4 oracle (all deliberate):
# 1. the middleware stays in the default stack with empty hosts (a
#    no-op) — Rails skips inserting it entirely; observable only via
#    `crails middleware` listing.
# 2. config.host_authorization = {exclude:, response_app:} becomes two
#    typed config properties; the response_app writes the response
#    context instead of returning a Rack triple.
# 3. the blocked-host debug page carries the same textual content
#    (heading, hint, config.hosts line, docs URL) without the gem's
#    full DebugView rescue chrome (CSS/JS layout); the "local requests"
#    condition maps to CRails.env.development?.
# 4. IPAddr entries are CRails::Middleware::IPCidr (CIDR strings); no
#    embedded-IPv6-v4 forms ("::ffff:1.2.3.4").
# 5. the block log line names CRails::Middleware::HostAuthorization
#    (the gem logs ActionDispatch::HostAuthorization).
