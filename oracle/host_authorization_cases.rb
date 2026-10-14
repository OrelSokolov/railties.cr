# Oracle: Rails 8.1.4 ActionDispatch::HostAuthorization.
# Runs against the throwaway devise app (devise.cr/tmp/http_app, 8.1.4).
# The middleware captures config.hosts when the stack is built (during
# boot), so every stage that touches config injects a stage initializer
# BEFORE requiring the environment and removes it at exit:
#   for stage in permissions dev_default blocked_non_local custom \
#                 exclude empty response_app; do
#     ruby host_authorization_cases.rb $stage >> host_authorization_expected.yml
#   done
require "ipaddr"
require "tmpdir"

def emit(id, value)
  puts "#{id}\t#{value}"
end

STAGE = ARGV[0] || "dev_default"
APP = "/home/oleg/rails.cr/devise.cr/tmp/http_app"

# Config injected before boot (initializer runs before build_middleware_stack).
def inject_stage_initializer!(body)
  File.write("#{APP}/config/initializers/zz_oracle_stage.rb", body)
  at_exit { File.delete("#{APP}/config/initializers/zz_oracle_stage.rb") rescue nil }
end

case STAGE
when "permissions"
  # --- unit matrix on the real Permissions matcher --------------------
  require "action_dispatch/middleware/host_authorization"
  perms = {
    "exact"                       => [["example.com"], "example.com"],
    "exact_port"                  => [["example.com"], "example.com:3000"],
    "exact_subdomain"             => [["example.com"], "www.example.com"],
    "exact_case_insensitive"      => [["example.com"], "EXAMPLE.COM"],
    "exact_other"                 => [["example.com"], "example.org"],
    "dot_root"                    => [[".example.com"], "example.com"],
    "dot_subdomain"               => [[".example.com"], "sub.example.com"],
    "dot_port"                    => [[".example.com"], "example.com:8080"],
    "dot_partial"                 => [[".example.com"], "subexample.com"],
    "dot_double_subdomain"        => [[".example.com"], "a.b.example.com"],
    "port_in_entry"               => [["example.com:3000"], "example.com"],
    "port_in_entry_other_port"    => [["example.com:3000"], "example.com:80"],
    "regexp_anchored"             => [[/\Awww\.example\.com\z/], "www.example.com"],
    "regexp_anchored_port"        => [[/\Awww\.example\.com\z/], "www.example.com:3000"],
    "regexp_partial_anchor"       => [[/^.*\.example\.com$/], "www.example.com"],
    "regexp_partial_anchor_port"  => [[/^.*\.example\.com$/], "www.example.com:3000"],
    "regexp_dev_sublocal"         => [[/^.+\.localhost$/], "a.localhost"],
    "cidr_v4_in"                  => [[IPAddr.new("192.168.0.0/16")], "192.168.1.1"],
    "cidr_v4_in_port"             => [[IPAddr.new("192.168.0.0/16")], "192.168.1.1:8080"],
    "cidr_v4_out"                 => [[IPAddr.new("192.168.0.0/16")], "192.169.0.1"],
    "cidr_v4_hostname"            => [[IPAddr.new("192.168.0.0/16")], "example.com"],
    "cidr_v4_localhost"           => [[IPAddr.new("192.168.0.0/16")], "localhost"],
    "cidr_any_v6"                 => [[IPAddr.new("::/0")], "::1"],
    "cidr_any_v6_port"            => [[IPAddr.new("::/0")], "[::1]:3000"],
    "cidr_any_v6_bare_port"       => [[IPAddr.new("::/0")], "::1:3000"],
    "cidr_single_v6"              => [[IPAddr.new("::1")], "[::1]:8080"],
    "cidr_single_v6_out"          => [[IPAddr.new("::1")], "::2"],
    "empty"                       => [[], "evil.com"],
    "multi_second"                => [["api.example.com", ".example.com"], "sub.example.com"],
    "multi_none"                  => [["api.example.com", ".example.com"], "www.api.example.com"],
  }
  perms.each do |id, (hosts, host)|
    begin
      allowed = ActionDispatch::HostAuthorization::Permissions.new(hosts).allows?(host)
    rescue => e
      allowed = "raise:#{e.class}"
    end
    emit("ha_perm_#{id}", allowed.inspect)
  end
  # empty? semantics
  emit("ha_perm_empty_predicate",
    ActionDispatch::HostAuthorization::Permissions.new([]).empty?.inspect)
else
  case STAGE
  when "dev_default"
    inject_stage_initializer!(
      "Rails.application.config.hosts = ActionDispatch::HostAuthorization::ALLOWED_HOSTS_IN_DEVELOPMENT\n")
  when "blocked_non_local"
    inject_stage_initializer!(
      "Rails.application.config.hosts = ActionDispatch::HostAuthorization::ALLOWED_HOSTS_IN_DEVELOPMENT\n" \
      "Rails.application.config.consider_all_requests_local = false\n")
  when "custom"
    inject_stage_initializer!(
      "Rails.application.config.hosts = [\"example.com\", \".dev.example.com\"]\n")
  when "exclude"
    inject_stage_initializer!(
      "Rails.application.config.hosts = [\"example.com\"]\n" \
      "Rails.application.config.host_authorization = { exclude: ->(request) { request.path == \"/healthcheck\" } }\n")
  when "empty"
    inject_stage_initializer!("Rails.application.config.hosts = []\n")
  when "response_app"
    inject_stage_initializer!(
      "Rails.application.config.hosts = [\"example.com\"]\n" \
      "Rails.application.config.host_authorization = { response_app: ->(env) { [418, {\"Content-Type\" => \"text/plain\"}, [\"teapot\"]] } }\n")
  end

  require "#{APP}/config/environment"
  session = ActionDispatch::Integration::Session.new(Rails.application)

  def get!(session, path, headers)
    session.get path, headers: headers
    session.response
  end

  case STAGE
  when "dev_default"
    # --- development default hosts: .localhost/.test + any IP ---------
    r = get!(session, "/users/sign_in", { "Host" => "localhost" })
    emit("ha_dev_localhost_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "localhost:3000" })
    emit("ha_dev_localhost_port_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "sub.localhost" })
    emit("ha_dev_sub_localhost_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "127.0.0.1" })
    emit("ha_dev_ip_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "testhost.test" })
    emit("ha_dev_test_tld_status", r.status.to_s)

    r = get!(session, "/users/sign_in", { "Host" => "evil.com" })
    emit("ha_dev_blocked_status", r.status.to_s)
    emit("ha_dev_blocked_content_type", r.headers["Content-Type"].inspect)
    emit("ha_dev_blocked_body_empty", r.body.empty?.inspect)
    emit("ha_dev_blocked_body_has_heading", r.body.include?("<h1>Blocked hosts: evil.com</h1>").inspect)
    emit("ha_dev_blocked_body_has_hint",
      r.body.include?("To allow requests to these hosts").inspect)
    emit("ha_dev_blocked_body_has_config_hint",
      r.body.include?('config.hosts &lt;&lt; "evil.com"').inspect)
    emit("ha_dev_blocked_body_has_docs_link",
      r.body.include?("https://guides.rubyonrails.org/configuring.html#actiondispatch-hostauthorization").inspect)

    r = get!(session, "/users/sign_in", { "Host" => "evil.com", "X-Requested-With" => "XMLHttpRequest" })
    emit("ha_dev_blocked_xhr_content_type", r.headers["Content-Type"].inspect)
    emit("ha_dev_blocked_xhr_status", r.status.to_s)

    # X-Forwarded-Host is checked too (last entry of the chain wins)
    r = get!(session, "/users/sign_in", { "Host" => "localhost", "X-Forwarded-Host" => "evil.com" })
    emit("ha_dev_forwarded_blocked_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "localhost", "X-Forwarded-Host" => "localhost, evil.com" })
    emit("ha_dev_forwarded_chain_blocked_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "localhost", "X-Forwarded-Host" => "sub.localhost" })
    emit("ha_dev_forwarded_ok_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "evil.com", "X-Forwarded-Host" => "localhost" })
    emit("ha_dev_origin_blocked_even_with_ok_forwarded", r.status.to_s)
    # two blocked hosts both land in the message
    r = get!(session, "/users/sign_in", { "Host" => "evil.com", "X-Forwarded-Host" => "bad.net" })
    emit("ha_dev_two_blocked_hosts_heading", r.body.include?("<h1>Blocked hosts: evil.com, bad.net</h1>").inspect)
  when "blocked_non_local"
    # consider_all_requests_local = false: no debug body
    r = get!(session, "/users/sign_in", { "Host" => "evil.com" })
    emit("ha_nonlocal_status", r.status.to_s)
    emit("ha_nonlocal_body_empty", r.body.empty?.inspect)
    emit("ha_nonlocal_content_length", r.headers["Content-Length"].inspect)
    emit("ha_nonlocal_content_type", r.headers["Content-Type"].inspect)
  when "custom"
    r = get!(session, "/users/sign_in", { "Host" => "example.com" })
    emit("ha_custom_exact_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "www.example.com" })
    emit("ha_custom_exact_subdomain_blocked", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "sub.dev.example.com" })
    emit("ha_custom_dot_subdomain_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "dev.example.com" })
    emit("ha_custom_dot_root_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "dev.example.org" })
    emit("ha_custom_dot_other_blocked", r.status.to_s)
  when "exclude"
    # excluded path passes through to the router (404, not 403)
    r = get!(session, "/healthcheck", { "Host" => "evil.com" })
    emit("ha_exclude_path_status", r.status.to_s)
    r = get!(session, "/users/sign_in", { "Host" => "evil.com" })
    emit("ha_exclude_other_still_blocked", r.status.to_s)
  when "empty"
    # empty hosts: middleware allows everything (Rails skips it entirely)
    r = get!(session, "/users/sign_in", { "Host" => "evil.com" })
    emit("ha_empty_hosts_status", r.status.to_s)
  when "response_app"
    r = get!(session, "/users/sign_in", { "Host" => "evil.com" })
    emit("ha_response_app_status", r.status.to_s)
    emit("ha_response_app_content_type", r.headers["Content-Type"].inspect)
    emit("ha_response_app_body", r.body.inspect)
  end
end
