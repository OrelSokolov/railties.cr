# Oracle spec: secure headers / Content-Security-Policy против
# oracle/secure_headers_expected.yml (rails 8.1.4, снят по стадиям —
# каждая стадия гема жила в отдельном процессе, т.к. стек фиксируется
# при первом build). Те же case-ID, те же ожидания. Значения — в
# ruby-inspect формате, как в оракуле.

require "spec"
require "../src/railties_cr"

SH_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/secure_headers_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

# Каждая стадия — своё приложение + свой сервер (как стадии оракула —
# свои процессы): стек строится при первом запросе, мутации config после
# первого запроса не действуют.
def sh_server(&app_config : CRails::Config ->) : Socket::IPAddress
  app = CRails::Application.new
  app_config.call(app.config)
  server = HTTP::Server.new do |context|
    app.call(context)
  end
  addr = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  sleep 20.milliseconds
  addr
end

def sh_get(addr : Socket::IPAddress, path : String = "/") : HTTP::Client::Response
  HTTP::Client.new(addr.address, addr.port) do |client|
    client.exec(HTTP::Request.new("GET", path))
  end
end

SH_HEADER_NAMES = %w[X-Frame-Options X-XSS-Protection X-Content-Type-Options
                     X-Permitted-Cross-Domain-Policies Referrer-Policy
                     Content-Security-Policy Content-Security-Policy-Report-Only]

describe "secure headers (rails 8.1.4 oracle)" do
  it "sh_default_* — Rails 8.1 default headers, no CSP" do
    addr = sh_server { |config| }
    response = sh_get(addr)
    SH_HEADER_NAMES.each do |name|
      id = "sh_default_#{name.tr("-", "_").downcase}"
      response.headers[name]?.inspect.should eq SH_EXPECTED[id]
    end
  end

  it "sh_csp_header — policy from the config block" do
    addr = sh_server do |config|
      config.content_security_policy do |policy|
        policy.default_src :self, :https
        policy.font_src    :self, :https, :data
        policy.img_src     :self, :https, :data
        policy.object_src  :none
        policy.script_src  :self
        policy.style_src   :self, :https
        policy.report_uri  "/csp-violation-report-endpoint"
      end
    end
    response = sh_get(addr)
    response.headers["Content-Security-Policy"]?.inspect.should eq SH_EXPECTED["sh_csp_header"]
    response.headers["Content-Security-Policy-Report-Only"]?.inspect
      .should eq SH_EXPECTED["sh_csp_report_only_header"]
  end

  it "sh_csp_symbol_mapping — symbol sources map like the gem" do
    addr = sh_server do |config|
      config.content_security_policy do |policy|
        policy.default_src :none
        policy.script_src  :self, :unsafe_inline, :unsafe_eval, :blob, :ws, :wss
        policy.style_src   "https://fonts.example.com", :data
        policy.connect_src "*"
      end
    end
    response = sh_get(addr)
    response.headers["Content-Security-Policy"]?.inspect
      .should eq SH_EXPECTED["sh_csp_symbol_mapping"]
  end

  it "sh_report_only_mode — report-only instead of enforce" do
    addr = sh_server do |config|
      config.content_security_policy do |policy|
        policy.default_src :self
      end
      config.content_security_policy_report_only = true
    end
    response = sh_get(addr)
    response.headers["Content-Security-Policy-Report-Only"]?.inspect
      .should eq SH_EXPECTED["sh_report_only_mode"]
    response.headers["Content-Security-Policy"]?.inspect
      .should eq SH_EXPECTED["sh_report_only_no_enforce"]
  end

  it "sh_default_header_override — config wins over the defaults" do
    addr = sh_server do |config|
      config.default_headers["X-Frame-Options"] = "DENY"
    end
    response = sh_get(addr)
    response.headers["X-Frame-Options"]?.inspect
      .should eq SH_EXPECTED["sh_default_header_override"]
  end
end
