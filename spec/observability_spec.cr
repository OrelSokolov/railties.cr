# Oracle spec: the Crystal port must reproduce
# oracle/observability_expected.yml (captured from rails 8.1.4 via
# oracle/observability_cases.rb). Same case IDs, same expectations, no
# edits on either side. Known deviations are asserted explicitly with
# (deviation) markers and listed at the bottom of this file.

require "spec"
require "log"
require "../src/railties_cr"

EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/observability_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

def normalize(s : String) : String
  s
    .gsub(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, "UUID")
    .gsub(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, "TS")
    .gsub(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}/, "TS")
    .gsub(/\d+(?:\.\d+)?ms/, "NUMms")
    .gsub(/\((\d+) queries, (\d+) cached\)/, "(NUM queries, NUM cached)")
end

LOG = IO::Memory.new

# The spec runner re-configures Log at startup (spec/dsl.cr calls
# Log.setup_from_env(default_level: :none)), wiping any binding made
# at the top level. (Re)bind lazily, once, from before_each.
module LogCapture
  @@done = false

  def self.setup! : Nil
    return if @@done
    @@done = true
    Log.builder.bind("crails", :info, Log::IOBackend.new(io: LOG))
  end
end

APP = CRails::Application.new

server = HTTP::Server.new do |context|
  APP.call(context)
end

module SpecEnv
  class_property addr : Socket::IPAddress?
end

SpecEnv.addr = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }
sleep 50.milliseconds

def get(path : String, headers : Hash(String, String) = {} of String => String)
  addr = SpecEnv.addr.not_nil!
  req = HTTP::Request.new("GET", path, headers: HTTP::Headers.new.tap { |h| headers.each { |k, v| h[k] = v } })
  HTTP::Client.new(addr.address, addr.port) do |client|
    client.exec(req)
  end
end

def log_tail : String
  LOG.to_s
end

# Drop the IOBackend prefix ("TS LEVEL - crails: ").
def message_part(line : String) : String
  line.strip.split(" - crails: ", 2).last? || line.strip
end

describe "observability (rails 8.1.4 oracle)" do
  before_each { LogCapture.setup! }
  # --- health endpoint ------------------------------------------------
  it "up_html_status" do
    get("/up").status_code.to_s.should eq EXPECTED["up_html_status"]
  end

  it "up_html_body" do
    get("/up").body.should eq EXPECTED["up_html_body"]
  end

  it "up_html_content_type" do
    get("/up").headers["Content-Type"].should eq EXPECTED["up_html_content_type"]
  end

  it "up_html_vary" do
    get("/up").headers["Vary"].should eq EXPECTED["up_html_vary"]
  end

  it "up_json_status" do
    get("/up.json").status_code.to_s.should eq EXPECTED["up_json_status"]
  end

  it "up_json_content_type" do
    get("/up.json").headers["Content-Type"].should eq EXPECTED["up_json_content_type"]
  end

  it "up_json_body_status" do
    JSON.parse(get("/up.json").body)["status"].to_s.should eq EXPECTED["up_json_body_status"]
  end

  it "up_json_body_timestamp_iso8601" do
    ts = JSON.parse(get("/up.json").body)["timestamp"].to_s
    Time.parse(ts, "%FT%TZ", Time::Location::UTC)
    "iso8601-parseable".should eq EXPECTED["up_json_body_timestamp_iso8601"]
  end

  # --- X-Request-Id ---------------------------------------------------
  it "request_id_uuid_v4_format" do
    rid = get("/up").headers["X-Request-Id"]? || ""
    result = rid =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/ ? "uuid-v4" : rid
    result.should eq EXPECTED["request_id_uuid_v4_format"]
  end

  it "request_id_changes_per_request" do
    a = get("/up").headers["X-Request-Id"]
    b = get("/up").headers["X-Request-Id"]
    (a == b ? "same" : "unique-per-request").should eq EXPECTED["request_id_changes_per_request"]
  end

  it "request_id_passthrough" do
    get("/up", {"X-Request-Id" => "test-id-123"}).headers["X-Request-Id"]
      .should eq EXPECTED["request_id_passthrough"]
  end

  it "request_id_response_header_present" do
    (get("/up").headers["X-Request-Id"]? ? "present" : "missing")
      .should eq EXPECTED["request_id_response_header_present"]
  end

  # --- 404 ------------------------------------------------------------
  it "not_found_status" do
    get("/nonexistent-observability").status_code.to_s.should eq EXPECTED["not_found_status"]
  end

  it "not_found_body_doctype" do
    get("/nonexistent-observability").body[0, 15].should eq EXPECTED["not_found_body_doctype"]
  end

  it "not_found_content_type" do
    get("/nonexistent-observability").headers["Content-Type"].should eq EXPECTED["not_found_content_type"]
  end

  it "not_found_request_id" do
    rid = get("/nonexistent-observability").headers["X-Request-Id"]? || ""
    result = rid =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/ ? "UUID" : rid
    result.should eq EXPECTED["not_found_request_id"]
  end

  # --- request log lines ----------------------------------------------
  it "log_started_line" do
    line = log_tail.lines.reverse.find(&.includes?("Started GET \"/up.json\"")).not_nil!
    normalize(message_part(line)).should eq EXPECTED["log_started_line"]
  end

  it "log_processing_line" do
    line = log_tail.lines.reverse.find(&.includes?("Processing by CRails::HealthController#show as JSON")).not_nil!
    normalize(message_part(line)).should eq EXPECTED["log_processing_line"]
      .gsub("Rails::HealthController", "CRails::HealthController")
    # (deviation) namespace: CRails vs Rails — see file footer.
  end

  it "log_completed_line" do
    line = log_tail.lines.reverse.find(&.includes?("Completed 200")).not_nil!
    ours = normalize(message_part(line))
    # (deviation) Rails logs view/AR/GC breakdown in parentheses; the
    # CRails P0 log has just the total duration.
    expected_prefix = EXPECTED["log_completed_line"].split(" (").first
    ours.should eq expected_prefix
  end

  it "log_not_found_line" do
    line = log_tail.lines.reverse.find { |l| l.includes?("Started") && l.includes?("nonexistent-observability") }.not_nil!
    normalize(message_part(line)).should eq EXPECTED["log_not_found_line"]
  end

  # --- CRails extensions (not in the Rails oracle) --------------------
  it "json log mode emits one JSON object per request" do
    app = CRails::Application.new
    app.config.log_json = true
    io = IO::Memory.new
    Log.builder.bind("crails", :info, Log::IOBackend.new(io: io))
    server2 = HTTP::Server.new { |ctx| app.call(ctx) }
    addr2 = server2.bind_tcp("127.0.0.1", 0)
    spawn { server2.listen }
    sleep 50.milliseconds
    HTTP::Client.new(addr2.address, addr2.port) { |c| c.get("/up") }

    # IOBackend prefixes each line with "TS LEVEL - crails: "; the
    # JSON entry is everything after the source marker.
    raw = io.to_s.lines.map(&.strip).reject(&.empty?).last
    entry = raw.split(" - crails: ", 2).last? || raw
    json = JSON.parse(entry)
    json["request_id"].as_s?.should_not be_nil
    json["method"].as_s.should eq "GET"
    json["path"].as_s.should eq "/up"
    json["status"].as_i.should eq 200
    json["duration_ms"].as_f.should be >= 0
    json["timestamp"].as_s.should_not be_nil
  end

  it "/metrics exposes prometheus text format" do
    resp = get("/metrics")
    resp.status_code.should eq 200
    resp.headers["Content-Type"].should start_with("text/plain")
    body = resp.body
    body.should contain("# HELP crails_http_requests_total")
    body.should contain("crails_http_request_duration_seconds_bucket{le=\"+Inf\"}")
    body.should contain("crails_http_requests_total{method=\"GET\",status=\"200\"}")
  end

  it "metrics counters increment" do
    before = CRails::Observability::METRICS.total_requests
    get("/up")
    CRails::Observability::METRICS.total_requests.should be > before
  end
end

# Known deviations from the rails 8.1.4 oracle (all deliberate P0):
# 1. log_processing_line: "CRails::HealthController" vs
#    "Rails::HealthController" — the CRails namespace.
# 2. log_completed_line: no (Views/ActiveRecord/GC) breakdown — no
#    per-layer instrumented timings yet.
# 3. /up does not send Rails' ETag/Cache-Control (render-fresh body).
# 4. JSON request logs + /metrics are CRails extensions (Rails 8 ships
#    neither out of the box).
