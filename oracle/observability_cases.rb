# Oracle cases for observability (Iteration 11): health endpoint,
# request-id, request logging. Captured from Rails 8.1.4.
#
# Start the reference app first (production, stdout log captured to a
# file), then:
#   PORT=3200 LOG_FILE=/tmp/rails8_oracle/server.log \
#     ruby oracle/observability_cases.rb > oracle/observability_expected.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in
# spec/observability_spec.cr. Volatile values are normalized in place:
# UUIDs -> UUID, timestamps -> TS, durations -> NUMms.

require "net/http"
require "json"
require "time"

PORT = Integer(ENV.fetch("PORT", "3200"))
LOG_FILE = ENV.fetch("LOG_FILE", "/tmp/rails8_oracle/server.log")

def http
  Net::HTTP.new("127.0.0.1", PORT)
end

def normalize(s)
  s
    .gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "UUID")
    .gsub(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, "TS")
    .gsub(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}/, "TS")
    .gsub(/\d+(?:\.\d+)?ms/, "NUMms")
    .gsub(/\((\d+) queries, (\d+) cached\)/, "(NUM queries, NUM cached)")
end

def case_run(id)
  puts "#{id}\t#{normalize(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

log_lines_before = File.read(LOG_FILE).lines.size

# --- health endpoint (Rails::HealthController, GET /up) ---------------
resp = http.get("/up")
case_run("up_html_status") { resp.code }
case_run("up_html_body") { resp.body }
case_run("up_html_content_type") { resp["Content-Type"] }
case_run("up_html_vary") { resp["Vary"] }

resp = http.get("/up.json")
parsed = JSON.parse(resp.body)
case_run("up_json_status") { resp.code }
case_run("up_json_content_type") { resp["Content-Type"] }
case_run("up_json_body_status") { parsed["status"] }
case_run("up_json_body_timestamp_iso8601") do
  Time.parse(parsed["timestamp"].to_s)
  "iso8601-parseable"
end

# --- X-Request-Id ------------------------------------------------------
resp = http.get("/up")
case_run("request_id_uuid_v4_format") do
  resp["X-Request-Id"] =~ /\A\h{8}-\h{4}-[1-5]\h{3}-[89ab]\h{3}-\h{12}\z/ ? "uuid-v4" : resp["X-Request-Id"]
end
case_run("request_id_changes_per_request") do
  a = http.get("/up")["X-Request-Id"]
  b = http.get("/up")["X-Request-Id"]
  a == b ? "same" : "unique-per-request"
end
resp = http.get("/up", "X-Request-Id" => "test-id-123")
case_run("request_id_passthrough") { resp["X-Request-Id"] }
case_run("request_id_response_header_present") { resp.key?("X-Request-Id") ? "present" : "missing" }

# --- 404 ---------------------------------------------------------------
resp = http.get("/nonexistent-observability")
case_run("not_found_status") { resp.code }
case_run("not_found_body_doctype") { resp.body[0, 15] }
case_run("not_found_content_type") { resp["Content-Type"] }
case_run("not_found_request_id") do
  resp["X-Request-Id"] =~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/ ? "UUID" : resp["X-Request-Id"]
end

# --- request log lines (Rails 8 LogSubscriber, tagged with request id) -
sleep 0.3
lines = File.read(LOG_FILE).lines[log_lines_before..] || []
started = lines.find { |l| l.include?('GET "/up.json"') }
rid = started && started[/\[(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\]/, 1]
tagged = rid ? lines.select { |l| l.include?("[#{rid}]") } : []

case_run("log_started_line") do
  l = tagged.find { |x| x.include?("Started") }
  l && l.strip.sub("[#{rid}]", "[UUID]")
end
case_run("log_processing_line") do
  l = tagged.find { |x| x.include?("Processing") }
  l && l.strip.sub("[#{rid}]", "[UUID]")
end
case_run("log_completed_line") do
  l = tagged.find { |x| x.include?("Completed") }
  l && l.strip.sub("[#{rid}]", "[UUID]")
end
case_run("log_not_found_line") do
  l = lines.find { |x| x.include?("Started") && x.include?("nonexistent-observability") }
  l && l.strip.sub(/\[[\h-]{36}\]/, "[UUID]")
end
