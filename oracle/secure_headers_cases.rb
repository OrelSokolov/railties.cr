# Oracle: Rails 8.1.4 secure headers / Content-Security-Policy.
# Runs inside a throwaway rails app (devise.cr/tmp/http_app, 8.1.4).
# The middleware stack and response default headers are captured when
# the app is first built, so each scenario runs in its own process:
#   for stage in default csp mapping report_only override; do
#     ruby secure_headers_cases.rb $stage >> secure_headers_expected.yml
#   end
require_relative "../../devise.cr/tmp/http_app/config/environment"

def emit(id, value)
  puts "#{id}\t#{value}"
end

stage = ARGV[0] || "default"
session = ActionDispatch::Integration::Session.new(Rails.application)
get = -> { session.get "/users/sign_in"; session.response.headers }

case stage
when "default"
  # no CSP configured: default_headers only, no CSP headers at all
  h = get.call
  %w[X-Frame-Options X-XSS-Protection X-Content-Type-Options
     X-Permitted-Cross-Domain-Policies Referrer-Policy
     Content-Security-Policy Content-Security-Policy-Report-Only].each do |name|
    emit("sh_default_#{name.tr('-', '_').downcase}", h[name].inspect)
  end
when "csp"
  Rails.application.config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self, :https
    policy.report_uri  "/csp-violation-report-endpoint"
  end
  h = get.call
  emit("sh_csp_header", h["Content-Security-Policy"].inspect)
  emit("sh_csp_report_only_header", h["Content-Security-Policy-Report-Only"].inspect)
when "mapping"
  # symbol -> source mapping
  Rails.application.config.content_security_policy do |policy|
    policy.default_src :none
    policy.script_src  :self, :unsafe_inline, :unsafe_eval, :blob, :ws, :wss
    policy.style_src   "https://fonts.example.com", :data
    policy.connect_src "*"
  end
  h = get.call
  emit("sh_csp_symbol_mapping", h["Content-Security-Policy"].inspect)
when "report_only"
  Rails.application.config.content_security_policy do |policy|
    policy.default_src :self
  end
  Rails.application.config.content_security_policy_report_only = true
  h = get.call
  emit("sh_report_only_mode", h["Content-Security-Policy-Report-Only"].inspect)
  emit("sh_report_only_no_enforce", h["Content-Security-Policy"].inspect)
when "override"
  # config.action_dispatch.default_headers set in config/application.rb
  # (before boot) wins over the built-ins — injected by the harness
  h = get.call
  emit("sh_default_header_override", h["X-Frame-Options"].inspect)
end
