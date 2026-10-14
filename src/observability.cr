# CRails::Observability — request ids, request logging, health endpoint
# and Prometheus metrics (Iteration 11).
#
# 1:1 with Rails 8.1.4 (oracle/observability_expected.yml, captured
# from rails 8.1.4 `rails/health_controller` + ActionDispatch::RequestId
# + LogSubscriber) for: X-Request-Id (UUID v4, passthrough), GET /up
# (HTML green / JSON {"status","timestamp"}), 404 HTML page, tagged
# text log lines. JSON log output and GET /metrics are CRails
# extensions (Rails 8 ships no JSON formatter and no metrics endpoint
# out of the box) — see ../PLAN.md "Deviations".

require "uuid"
require "json"

module CRails
  module Observability
    # --- X-Request-Id (ActionDispatch::RequestId port) ----------------
    # Incoming value is passed through verbatim (even non-UUID — the
    # oracle passes "test-id-123" through), otherwise a UUID v4 is
    # generated per request.
    REQUEST_ID_HEADER = "X-Request-Id"

    def self.request_id(context : HTTP::Server::Context) : String
      incoming = context.request.headers[REQUEST_ID_HEADER]?
      return incoming if incoming && !incoming.empty?
      UUID.random.to_s
    end

    # --- health endpoint (Rails::HealthController port) ---------------
    # Up renders green HTML / JSON; any exception inside the check
    # renders red + 500. Like Rails, no dependencies are checked.

    UP_HTML = "<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>"
    UP_HTML_DOWN = "<!DOCTYPE html><html><body style=\"background-color: red\"></body></html>"

    def self.health_response(context : HTTP::Server::Context) : Nil
      json = context.request.path.ends_with?(".json")
      begin
        respond_health(context, 200, UP_HTML, "up", json)
      rescue ex : Exception
        CRails.logger.error(exception: ex) { "health check failed" }
        respond_health(context, 500, UP_HTML_DOWN, "down", json)
      end
    end

    private def self.respond_health(context, status, html, status_word, json) : Nil
      response = context.response
      response.status_code = status
      if json
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        response.print({"status" => status_word, "timestamp" => Time.utc.to_s("%FT%TZ")}.to_json)
      else
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        response.headers["Vary"] = "Accept"
        response.print html
      end
    end

    # --- Prometheus metrics --------------------------------------------
    # Text exposition format 0.0.4. Counters live in a constant (NOT a
    # class_property: mutating through its getter hands out separate
    # instances).

    class Metrics
      BUCKETS = {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0}

      def initialize
        @mutex = Mutex.new
        @requests = Hash(Tuple(String, Int32), Int64).new(0_i64)
        @duration_counts = Array(Int64).new(BUCKETS.size + 1, 0_i64) # last = +Inf
        @duration_sum = 0.0_f64
        @total = Atomic(Int64).new(0_i64)
      end

      def observe(method : String, status : Int32, duration_seconds : Float64) : Nil
        @total.add(1)
        @mutex.synchronize do
          @requests[{method, status}] += 1_i64
          @duration_sum += duration_seconds
          BUCKETS.each_with_index do |bound, i|
            @duration_counts[i] += 1_i64 if duration_seconds <= bound
          end
          @duration_counts[BUCKETS.size] += 1_i64 # +Inf
        end
      end

      def total_requests : Int64
        @total.get
      end

      def to_s(io : IO) : Nil
        io << "# HELP crails_http_requests_total Total HTTP requests.\n"
        io << "# TYPE crails_http_requests_total counter\n"
        @mutex.synchronize do
          @requests.each do |(method, status), count|
            io << "crails_http_requests_total{method=\"" << method << "\",status=\"" << status << "\"} " << count << '\n'
          end
          io << "# HELP crails_http_request_duration_seconds HTTP request duration.\n"
          io << "# TYPE crails_http_request_duration_seconds histogram\n"
          BUCKETS.each_with_index do |bound, i|
            io << "crails_http_request_duration_seconds_bucket{le=\"" << bound << "\"} " << @duration_counts[i] << '\n'
          end
          io << "crails_http_request_duration_seconds_bucket{le=\"+Inf\"} " << @duration_counts[BUCKETS.size] << '\n'
          io << "crails_http_request_duration_seconds_count " << @duration_counts[BUCKETS.size] << '\n'
          io << "crails_http_request_duration_seconds_sum " << @duration_sum << '\n'
        end
        io << "# HELP crails_rss_bytes Resident set size in bytes.\n"
        io << "# TYPE crails_rss_bytes gauge\n"
        io << "crails_rss_bytes " << rss_bytes << '\n'
      end

      private def rss_bytes : Int64
        status = File.read("/proc/self/status")
        if (line = status.each_line.find(&.starts_with?("VmRSS:")))
          line.split[1].to_i64 * 1024
        else
          0_i64
        end
      rescue
        0_i64
      end
    end

    METRICS = Metrics.new

    def self.metrics_response(context : HTTP::Server::Context) : Nil
      context.response.status_code = 200
      context.response.headers["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"
      METRICS.to_s(context.response)
    end

    # Serves /up and /metrics before routing (unless the app defines
    # its own route for the path). The health handler reports itself as
    # CRails::HealthController (the Rails oracle logs Rails::HealthController).
    def self.builtin?(context : HTTP::Server::Context, routes : CRails::Routes::RouteSet, rid : String? = nil, log_json : Bool = true) : Bool
      path = context.request.path
      return false if routes.match(context.request.method, path)
      case path
      when "/up", "/up.json"
        unless log_json
          format = path.ends_with?(".json") ? "JSON" : "HTML"
          CRails.logger.info { log_processing(rid || "-", "CRails::HealthController", "show", format) }
        end
        health_response(context)
        true
      when "/metrics"
        metrics_response(context)
        true
      else
        false
      end
    end

    # --- request logging ------------------------------------------------
    # Text mode mirrors the Rails 8 LogSubscriber lines, tagged with
    # the request id. JSON mode (our extension) emits one JSON object
    # per request.

    def self.log_started(rid : String, context : HTTP::Server::Context) : String
      ip = client_ip(context)
      ts = Time.local.to_s("%F %T %z")
      "[#{rid}] Started #{context.request.method} \"#{context.request.path}\" for #{ip} at #{ts}"
    end

    def self.log_processing(rid : String, controller : String, action : String, format : String?) : String
      line = "[#{rid}] Processing by #{controller}##{action}"
      line += " as #{format}" if format
      line
    end

    def self.log_completed(rid : String, status : Int32, duration_ms : Float64) : String
      phrase = HTTP::Status.new(status).description
      "[#{rid}] Completed #{status}#{phrase ? " #{phrase}" : ""} in #{duration_ms.round(2)}ms"
    end

    def self.log_json_entry(rid : String, context : HTTP::Server::Context, status : Int32, duration_ms : Float64) : String
      {
        "timestamp"    => Time.utc.to_s("%FT%T.%3NZ"),
        "level"        => "INFO",
        "request_id"   => rid,
        "method"       => context.request.method,
        "path"         => context.request.path,
        "status"       => status,
        "duration_ms"  => duration_ms.round(2),
        "ip"           => client_ip(context),
      }.to_json
    end

    def self.client_ip(context : HTTP::Server::Context) : String
      if (fwd = context.request.headers["X-Forwarded-For"]?) && !fwd.empty?
        return fwd.split(',').first.strip
      end
      addr = context.request.remote_address
      case addr
      when Socket::IPAddress then addr.address.to_s
      else                        "unknown"
      end
    end
  end
end
