# Oracle: Rails 8.1.4 ActionDispatch::SSL / AssumeSSL.
# Same harness as host_authorization_cases.rb (stage per process, config
# injected via a stage initializer before boot):
#   for stage in redirect_default redirect_status_default redirect_status \
#                 hsts_custom hsts_false redirect_host_port redirect_exclude \
#                 redirect_false assume_ssl secure_cookies; do
#     ruby ssl_cases.rb $stage >> ssl_expected.yml
#   done
require "tmpdir"

def emit(id, value)
  puts "#{id}\t#{value}"
end

STAGE = ARGV[0] || "redirect_default"
APP = "/home/oleg/rails.cr/devise.cr/tmp/http_app"

def inject_stage_initializer!(body)
  File.write("#{APP}/config/initializers/zz_oracle_stage.rb", body)
  at_exit { File.delete("#{APP}/config/initializers/zz_oracle_stage.rb") rescue nil }
end

FORCE_SSL = "Rails.application.config.force_ssl = true\n"

case STAGE
when "secure_cookies"
  inject_stage_initializer!(FORCE_SSL)
  require "#{APP}/config/environment"
  session = ActionDispatch::Integration::Session.new(Rails.application)

  # https request setting a session cookie: "; secure" is appended
  session.post "/users/sign_in", params: { user: { email: "x@x.x", password: "bad" } },
    headers: { "Host" => "example.org", "X-Forwarded-Proto" => "https" }
  cookies = session.response.headers["Set-Cookie"]
  emit("ssl_sc_https_flagged",
    Array(cookies).map { |c| c.include?("; secure") && !c.start_with?("; secure") ? "flagged" : c }.inspect)
else
  case STAGE
  when "redirect_default"      then inject_stage_initializer!(FORCE_SSL)
  when "redirect_status_default"
    inject_stage_initializer!(FORCE_SSL +
      "Rails.application.config.action_dispatch.ssl_default_redirect_status = 308\n")
  when "redirect_status"
    inject_stage_initializer!(FORCE_SSL +
      "Rails.application.config.ssl_options = { redirect: { status: 302 } }\n")
  when "hsts_custom"
    inject_stage_initializer!(FORCE_SSL +
      "Rails.application.config.ssl_options = { hsts: { expires: 3600, subdomains: false, preload: true } }\n")
  when "hsts_false"
    inject_stage_initializer!(FORCE_SSL +
      "Rails.application.config.ssl_options = { hsts: false }\n")
  when "redirect_host_port"
    inject_stage_initializer!(FORCE_SSL +
      "Rails.application.config.ssl_options = { redirect: { host: \"secure.example.com\", port: 8080 } }\n")
  when "redirect_exclude"
    inject_stage_initializer!(FORCE_SSL +
      "Rails.application.config.ssl_options = { redirect: { exclude: ->(request) { request.path == \"/users/sign_in\" } } }\n")
  when "redirect_false"
    inject_stage_initializer!(FORCE_SSL +
      "Rails.application.config.ssl_options = { redirect: false }\n")
  when "assume_ssl"
    inject_stage_initializer!(FORCE_SSL +
      "Rails.application.config.assume_ssl = true\n")
  end

  require "#{APP}/config/environment"
  session = ActionDispatch::Integration::Session.new(Rails.application)

  def req!(session, method, path, headers)
    session.public_send(method, path, headers: headers)
    session.response
  end

  case STAGE
  when "redirect_default"
    r = req!(session, :get, "/users/sign_in?foo=bar&baz=1", { "Host" => "example.org" })
    emit("ssl_rd_get_status", r.status.to_s)
    emit("ssl_rd_get_location", r.headers["Location"].inspect)
    emit("ssl_rd_get_content_type", r.headers["Content-Type"].inspect)
    emit("ssl_rd_get_body_empty", r.body.empty?.inspect)

    r = req!(session, :post, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rd_post_status", r.status.to_s)
    emit("ssl_rd_post_location", r.headers["Location"].inspect)

    r = req!(session, :delete, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rd_delete_status", r.status.to_s)

    r = req!(session, :head, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rd_head_status", r.status.to_s)

    # X-Forwarded-Proto: https counts as ssl — no redirect, HSTS applied
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org", "X-Forwarded-Proto" => "https" })
    emit("ssl_rd_forwarded_status", r.status.to_s)
    emit("ssl_rd_forwarded_hsts", r.headers["Strict-Transport-Security"].inspect)

    # non-default port in Host is kept in the redirect location
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org:3000" })
    emit("ssl_rd_port_kept_location", r.headers["Location"].inspect)

    # no query — location is the bare path
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rd_no_query_location", r.headers["Location"].inspect)
  when "redirect_status_default"
    # explicit ssl_default_redirect_status wins over the 307 default
    r = req!(session, :delete, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rsd_delete_status", r.status.to_s)
    # GET/HEAD still permanently redirect
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rsd_get_status", r.status.to_s)
  when "redirect_status"
    # explicit redirect.status wins for every method
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rs_get_status", r.status.to_s)
    r = req!(session, :post, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rs_post_status", r.status.to_s)
  when "hsts_custom"
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org", "X-Forwarded-Proto" => "https" })
    emit("ssl_hsts_custom_header", r.headers["Strict-Transport-Security"].inspect)
    # http request: redirected, no HSTS on the redirect response
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_hsts_custom_http_hsts", r.headers["Strict-Transport-Security"].inspect)
  when "hsts_false"
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org", "X-Forwarded-Proto" => "https" })
    emit("ssl_hsts_false_header", r.headers["Strict-Transport-Security"].inspect)
  when "redirect_host_port"
    r = req!(session, :get, "/users/sign_in?foo=bar", { "Host" => "example.org" })
    emit("ssl_rhp_location", r.headers["Location"].inspect)
  when "redirect_exclude"
    # excluded path: http passes through unredirected
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rex_status", r.status.to_s)
    emit("ssl_rex_hsts", r.headers["Strict-Transport-Security"].inspect)
    # non-excluded path still redirects
    r = req!(session, :get, "/users/sign_up", { "Host" => "example.org" })
    emit("ssl_rex_other_status", r.status.to_s)
  when "redirect_false"
    # redirect: false — nothing is ever redirected, HSTS/secure-cookies off
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_rf_status", r.status.to_s)
    emit("ssl_rf_hsts", r.headers["Strict-Transport-Security"].inspect)
  when "assume_ssl"
    # AssumeSSL forces https before SSL runs: no redirect even over http
    r = req!(session, :get, "/users/sign_in", { "Host" => "example.org" })
    emit("ssl_as_status", r.status.to_s)
    emit("ssl_as_hsts", r.headers["Strict-Transport-Security"].inspect)
  end
end
