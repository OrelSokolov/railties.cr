# CRails::OTel — zero-config OpenTelemetry tracing (Iteration 11).
#
# Rails 8 has no built-in OTel exporter (you wire otel-ruby gems by
# hand); CRails ships a P0 equivalent: set OTEL_EXPORTER_OTLP_ENDPOINT
# (or OTEL_EXPORTER_OTLP_HTTP_ENDPOINT) and every HTTP request is
# reported as a server span via OTLP/JSON POST to {endpoint}/v1/traces.
# No env vars -> this module is inert: zero hot-path cost beyond one
# nil check per request.
#
# Spans are also published as ActiveSupport::Notifications events
# ("crails.http") so subscribers/instrumentation have a seam.

require "http/client"
require "json"

module CRails
  module OTel
    @@endpoint : String?

    def self.endpoint : String?
      @@endpoint ||= begin
        raw = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]? || ENV["OTEL_EXPORTER_OTLP_HTTP_ENDPOINT"]?
        raw.try(&.rchop('/'))
      end
    end

    def self.service_name : String
      ENV["OTEL_SERVICE_NAME"]? || "crails"
    end

    def self.enabled? : Bool
      !endpoint.nil?
    end

    # Records one server span for a finished HTTP request and ships it
    # (fire-and-forget fiber) as an OTLP/JSON ExportTraceServiceRequest.
    def self.record_http_span(rid : String, method : String, path : String,
                               status : Int32, duration_seconds : Float64) : Nil
      ep = endpoint
      return unless ep

      now_nanos = Time.utc.to_unix_ns
      span = {
        "traceId"  => rid.delete('-').rjust(32, '0'),
        "spanId"   => Random::Secure.hex(4),
        "name"     => "#{method} #{path}",
        "kind"     => 2, # SERVER
        "startTimeUnixNano" => now_nanos - (duration_seconds * 1_000_000_000).to_i64,
        "endTimeUnixNano"   => now_nanos,
        "attributes" => [
          {"key" => "http.request.method", "value" => {"stringValue" => method}},
          {"key" => "url.path", "value" => {"stringValue" => path}},
          {"key" => "http.response.status_code", "value" => {"intValue" => status}},
          {"key" => "crails.request_id", "value" => {"stringValue" => rid}},
        ],
        "status" => {"code" => (status < 500 ? 1 : 2)},
      }
      body = {
        "resourceSpans" => [{
          "resource" => {
            "attributes" => [
              {"key" => "service.name", "value" => {"stringValue" => service_name}},
            ],
          },
          "scopeSpans" => [{"spans" => [span]}],
        }],
      }.to_json

      spawn { export(ep, body) }
    end

    private def self.export(ep : String, body : String) : Nil
      HTTP::Client.post("#{ep}/v1/traces", body: body,
        headers: HTTP::Headers{"Content-Type" => "application/json"}) do |resp|
        end
    rescue ex : Exception
      CRails.logger.warn { "otel export failed: #{ex.message}" }
    end
  end
end
