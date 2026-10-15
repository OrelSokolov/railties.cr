# CRails.logger: RAILS_LOG_LEVEL/CRAILS_LOG_LEVEL понижает severity —
# harness и production передают warn, чтобы не платить JSON-строку на
# каждый запрос; без env — дефолт Crystal (info).

require "spec"
require "../src/railties_cr"

describe "CRails.logger severity" do
  it "resolves RAILS_LOG_LEVEL to a severity" do
    ENV["RAILS_LOG_LEVEL"] = "warn"
    ENV.delete("CRAILS_LOG_LEVEL")
    CRails.env_log_severity.should eq(Log::Severity::Warn)
  end

  it "prefers CRAILS_LOG_LEVEL and is case-insensitive" do
    ENV["RAILS_LOG_LEVEL"] = "info"
    ENV["CRAILS_LOG_LEVEL"] = "ERROR"
    CRails.env_log_severity.should eq(Log::Severity::Error)
  end

  it "returns nil without env or for an unknown level" do
    ENV.delete("RAILS_LOG_LEVEL")
    ENV.delete("CRAILS_LOG_LEVEL")
    CRails.env_log_severity.should be_nil
    ENV["RAILS_LOG_LEVEL"] = "verbose"
    CRails.env_log_severity.should be_nil
    ENV.delete("RAILS_LOG_LEVEL")
  end

  it "maps the full Rails ladder including none" do
    {"debug" => Log::Severity::Debug, "info" => Log::Severity::Info,
     "warn" => Log::Severity::Warn, "error" => Log::Severity::Error,
     "fatal" => Log::Severity::Fatal, "none" => Log::Severity::None}
      .each { |name, severity| CRails::LOG_LEVELS[name].should eq(severity) }
  end
end
