# Oracle spec: the Crystal port must reproduce oracle/ssl_expected.yml
# (captured from rails 8.1.4 via oracle/ssl_cases.rb). Same case IDs,
# same expectations, no edits on either side. Known deviations are
# asserted explicitly with (deviation) markers and listed at the bottom
# of this file.
#
# "https" requests are X-Forwarded-Proto: https (the carrier the
# AssumeSSL middleware writes); http://* locations come from the Host
# header, like Rack's request.host.

require "spec"
require "../src/railties_cr"

SSL_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/ssl_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

class SslSignInController < ActionController::Base
  def sign_in
    render plain: "sign in page"
  end
end

SSL_APP = CRails::Application.new.tap do |app|
  app.routes.draw do
    get "/users/sign_in", to: "ssl_sign_in#sign_in"
  end
  # the oracle app's development.rb clears config.hosts; mirror that so
  # the Host examples target the SSL middleware, not host authorization
  app.config.hosts = [] of CRails::Middleware::HostEntry
end

# Separate app for the secure-cookies stage: the chain is memoized
# after the first request, so the CookieSetter middleware must be
# configured up front.
class SslCookieSetter
  include HTTP::Handler

  def call(context : HTTP::Server::Context) : Nil
    context.response.headers.add("Set-Cookie", "a=1")
    call_next(context)
  end
end

SSL_COOKIE_APP = CRails::Application.new.tap do |app|
  app.routes.draw do
    get "/users/sign_in", to: "ssl_sign_in#sign_in"
  end
  app.config.force_ssl = true
  app.config.hosts = [] of CRails::Middleware::HostEntry
  app.config.middleware.insert_after(CRails::Middleware::SSL, SslCookieSetter)
end

module SpecSsl
  class_property addr : Socket::IPAddress?
  class_property cookie_addr : Socket::IPAddress?
end

ssl_server = HTTP::Server.new { |ctx| SSL_APP.call(ctx) }
SpecSsl.addr = ssl_server.bind_tcp("127.0.0.1", 0)
spawn { ssl_server.listen }

ssl_cookie_server = HTTP::Server.new { |ctx| SSL_COOKIE_APP.call(ctx) }
SpecSsl.cookie_addr = ssl_cookie_server.bind_tcp("127.0.0.1", 0)
spawn { ssl_cookie_server.listen }
sleep 50.milliseconds

def ssl_req(path : String, method : String = "GET", host : String? = nil,
            extra : Hash(String, String) = {} of String => String,
            cookie : Bool = false) : HTTP::Client::Response
  req = HTTP::Request.new(method, path)
  req.headers["Host"] = host if host
  extra.each { |k, v| req.headers[k] = v }
  addr = cookie ? SpecSsl.cookie_addr.not_nil! : SpecSsl.addr.not_nil!
  HTTP::Client.new(addr.address, addr.port) { |c| c.exec(req) }
end

describe "ssl middleware (rails 8.1.4 oracle)" do
  before_each do
    SSL_APP.config.force_ssl = false
    SSL_APP.config.assume_ssl = false
    SSL_APP.config.ssl_options = CRails::SSLOptions.new
  end

  # --- default redirect (301 GET/HEAD, 308 otherwise in Rails 8.1) ----
  it "ssl_rd_get" do
    SSL_APP.config.force_ssl = true
    r = ssl_req("/users/sign_in?foo=bar&baz=1", host: "example.org")
    r.status_code.to_s.should eq SSL_EXPECTED["ssl_rd_get_status"]
    r.headers["Location"].inspect.should eq SSL_EXPECTED["ssl_rd_get_location"]
    r.headers["Content-Type"].inspect.should eq SSL_EXPECTED["ssl_rd_get_content_type"]
    (r.body || "").empty?.inspect.should eq SSL_EXPECTED["ssl_rd_get_body_empty"]
  end

  it "ssl_rd_post" do
    SSL_APP.config.force_ssl = true
    r = ssl_req("/users/sign_in", "POST", host: "example.org")
    r.status_code.to_s.should eq SSL_EXPECTED["ssl_rd_post_status"]
    r.headers["Location"].inspect.should eq SSL_EXPECTED["ssl_rd_post_location"]
  end

  it "ssl_rd_delete" do
    SSL_APP.config.force_ssl = true
    ssl_req("/users/sign_in", "DELETE", host: "example.org").status_code.to_s
      .should eq SSL_EXPECTED["ssl_rd_delete_status"]
  end

  it "ssl_rd_head" do
    SSL_APP.config.force_ssl = true
    ssl_req("/users/sign_in", "HEAD", host: "example.org").status_code.to_s
      .should eq SSL_EXPECTED["ssl_rd_head_status"]
  end

  it "ssl_rd_forwarded" do
    SSL_APP.config.force_ssl = true
    r = ssl_req("/users/sign_in", host: "example.org",
      extra: {"X-Forwarded-Proto" => "https"})
    r.status_code.to_s.should eq SSL_EXPECTED["ssl_rd_forwarded_status"]
    r.headers["Strict-Transport-Security"]?.inspect
      .should eq SSL_EXPECTED["ssl_rd_forwarded_hsts"]
  end

  it "ssl_rd_port_kept_location" do
    SSL_APP.config.force_ssl = true
    ssl_req("/users/sign_in", host: "example.org:3000").headers["Location"].inspect
      .should eq SSL_EXPECTED["ssl_rd_port_kept_location"]
  end

  it "ssl_rd_no_query_location" do
    SSL_APP.config.force_ssl = true
    ssl_req("/users/sign_in", host: "example.org").headers["Location"].inspect
      .should eq SSL_EXPECTED["ssl_rd_no_query_location"]
  end

  # --- config.action_dispatch.ssl_default_redirect_status ---------------
  it "ssl_rsd" do
    SSL_APP.config.force_ssl = true
    SSL_APP.config.ssl_default_redirect_status = 308
    ssl_req("/users/sign_in", "DELETE", host: "example.org").status_code.to_s
      .should eq SSL_EXPECTED["ssl_rsd_delete_status"]
    ssl_req("/users/sign_in", host: "example.org").status_code.to_s
      .should eq SSL_EXPECTED["ssl_rsd_get_status"]
  end

  # --- explicit redirect.status ------------------------------------------
  it "ssl_rs" do
    SSL_APP.config.force_ssl = true
    SSL_APP.config.ssl_options.redirect.status = 302
    ssl_req("/users/sign_in", host: "example.org").status_code.to_s
      .should eq SSL_EXPECTED["ssl_rs_get_status"]
    ssl_req("/users/sign_in", "POST", host: "example.org").status_code.to_s
      .should eq SSL_EXPECTED["ssl_rs_post_status"]
  end

  # --- hsts options -------------------------------------------------------
  it "ssl_hsts_custom" do
    SSL_APP.config.force_ssl = true
    SSL_APP.config.ssl_options.hsts.expires = 3600_i64
    SSL_APP.config.ssl_options.hsts.subdomains = false
    SSL_APP.config.ssl_options.hsts.preload = true
    r = ssl_req("/users/sign_in", host: "example.org",
      extra: {"X-Forwarded-Proto" => "https"})
    r.headers["Strict-Transport-Security"]?.inspect
      .should eq SSL_EXPECTED["ssl_hsts_custom_header"]
    # http redirect responses never carry HSTS
    ssl_req("/users/sign_in", host: "example.org")
      .headers["Strict-Transport-Security"]?.inspect
      .should eq SSL_EXPECTED["ssl_hsts_custom_http_hsts"]
  end

  it "ssl_hsts_false" do
    # hsts: false still sends the header — with max-age=0 to expire the
    # browser's cached setting
    SSL_APP.config.force_ssl = true
    SSL_APP.config.ssl_options.hsts = false
    ssl_req("/users/sign_in", host: "example.org",
      extra: {"X-Forwarded-Proto" => "https"})
      .headers["Strict-Transport-Security"]?.inspect
      .should eq SSL_EXPECTED["ssl_hsts_false_header"]
  end

  # --- redirect destination host/port --------------------------------------
  it "ssl_rhp_location" do
    SSL_APP.config.force_ssl = true
    SSL_APP.config.ssl_options.redirect.host = "secure.example.com"
    SSL_APP.config.ssl_options.redirect.port = 8080
    ssl_req("/users/sign_in?foo=bar", host: "example.org").headers["Location"].inspect
      .should eq SSL_EXPECTED["ssl_rhp_location"]
  end

  # --- redirect exclude -----------------------------------------------------
  it "ssl_rex" do
    SSL_APP.config.force_ssl = true
    SSL_APP.config.ssl_options.redirect.exclude = ->(context : HTTP::Server::Context) do
      context.request.path == "/users/sign_in"
    end
    r = ssl_req("/users/sign_in", host: "example.org")
    r.status_code.to_s.should eq SSL_EXPECTED["ssl_rex_status"]
    r.headers["Strict-Transport-Security"]?.inspect
      .should eq SSL_EXPECTED["ssl_rex_hsts"]
    # a non-excluded path still redirects
    ssl_req("/users/sign_up", host: "example.org").status_code.to_s
      .should eq SSL_EXPECTED["ssl_rex_other_status"]
  end

  # --- redirect: false -------------------------------------------------------
  it "ssl_rf" do
    SSL_APP.config.force_ssl = true
    SSL_APP.config.ssl_options.redirect = false
    r = ssl_req("/users/sign_in", host: "example.org")
    r.status_code.to_s.should eq SSL_EXPECTED["ssl_rf_status"]
    r.headers["Strict-Transport-Security"]?.inspect
      .should eq SSL_EXPECTED["ssl_rf_hsts"]
  end

  # --- assume_ssl --------------------------------------------------------------
  it "ssl_as" do
    SSL_APP.config.force_ssl = true
    SSL_APP.config.assume_ssl = true
    r = ssl_req("/users/sign_in", host: "example.org")
    r.status_code.to_s.should eq SSL_EXPECTED["ssl_as_status"]
    r.headers["Strict-Transport-Security"]?.inspect
      .should eq SSL_EXPECTED["ssl_as_hsts"]
  end

  # --- secure cookies ------------------------------------------------------------
  it "ssl_sc_https_flagged" do
    r = ssl_req("/users/sign_in", host: "example.org",
      extra: {"X-Forwarded-Proto" => "https"}, cookie: true)
    flagged = (r.headers.get?("Set-Cookie") || [] of String).map do |c|
      c.includes?("; secure") && !c.starts_with?("; secure") ? "flagged" : c
    end
    flagged.inspect.should eq SSL_EXPECTED["ssl_sc_https_flagged"]
  end

  # --- CRails specifics (not 1:1 with the Rails oracle list) ---------------
  it "force_ssl off is a no-op" do
    # the middleware stays in the stack; without force_ssl nothing happens
    r = ssl_req("/users/sign_in", host: "example.org")
    r.status_code.should eq 200
    r.headers["Strict-Transport-Security"]?.should be_nil
  end

  it "secure flag is not appended twice" do
    SSL_COOKIE_APP.config.ssl_options.hsts = false
    r = ssl_req("/users/sign_in?double=1", host: "example.org",
      extra: {"X-Forwarded-Proto" => "https"}, cookie: true)
    cookies = r.headers.get?("Set-Cookie") || [] of String
    # the app sets "a=1"; the controller-side session/CSRF jar may add
    # more — every cookie must carry exactly one "; secure"
    cookies.each do |c|
      c.should match(/;\s*secure\s*(;|$)/)
      c.scan(/;\s*secure\s*(;|$)/i).size.should eq 1
    end
  end
end

# Known deviations from the rails 8.1.4 oracle (all deliberate):
# 1. both middlewares are always in the default stack, reading
#    config.force_ssl / config.assume_ssl at call time (off -> no-op);
#    Rails composes the stack after environments/*.cr, so it simply
#    skips inserting them — observable only via `crails middleware`.
# 2. config.ssl_options is a typed CRails::SSLOptions object, not a
#    Hash: redirect.host/port/status/body/exclude, redirect.enabled? =
#    false (== redirect: false), hsts.expires = 0 (== hsts: false).
# 3. ssl detection is X-Forwarded-Proto based (Rack reads the env's
#    url_scheme/HTTPS, set by the frontend server or AssumeSSL);
#    directly TLS-serving processes need assume_ssl or a proxy.
# 4. the redirect body is a String, not an Array.
# 5. the secure-cookies oracle case ran through a devise session cookie;
#    the mirror sets Set-Cookie from a test middleware (the controller
#    side has no session jar in this spec app).
