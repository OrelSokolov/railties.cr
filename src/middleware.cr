# CRails::MiddlewareStack — ActionDispatch::MiddlewareStack port
# (Rails 8.1.4): an ordered list of HTTP::Handler classes composed into
# a chain at boot. Oracle: oracle/middleware_expected.yml (captured
# from a real 8.1.4 app, railties.cr/oracle/middleware_cases.rb);
# mirrored in spec/middleware_spec.cr.
#
# Mapping to the Rails 8.1 default stack (default_stack_names oracle):
# RequestId -> Middleware::RequestId, Rails::Rack::Logger (+ LogSubscriber,
# Rack::Runtime) -> Middleware::RequestLogger, ShowExceptions (+ DebugExceptions)
# -> Middleware::ShowExceptions, Rack::Head -> Middleware::Head.
# Cookies/Session/Flash stay controller-side (documented deviation:
# no per-request env to preload jars into — they read the Cookie header
# lazily and commit Set-Cookie directly). Static has a counterpart:
# Middleware::Static (port of ActionDispatch::Static, oracle
# oracle/static_expected.yml; also serves vite-asset builds from
# public/ with immutable caching). HostAuthorization/AssumeSSL/SSL have
# counterparts in host_authorization.cr / ssl.cr (always in the stack,
# config read at call time — see the deviation notes there). The
# remaining Rails entries (Sendfile, Executor, ServerTiming,
# LocalCache, MethodOverride, RemoteIp, ConditionalGet, ETag,
# TempfileReaper, propshaft/reloader/AR-specific) have no CRails
# counterpart yet — see ../PLAN.md.

require "http/server/handler"

module CRails
  class MiddlewareStack
    # One stack entry (ActionDispatch::MiddlewareStack::Middleware
    # port). Crystal has no virtual metaclass over a module's includers
    # (`HTTP::Handler.class` is the module singleton), so the node keeps
    # the class name plus a builder proc; everything (==, delete,
    # insert_before targets) matches by name — exactly like Ruby's
    # `m.name == klass.name`. Deviation from Ruby: no constructor
    # args/blocks — CRails middlewares read CRails.application.config at
    # call time, the way Rails' own configurable ones (CSP, Static) read
    # `request.env` / config anyway.
    class Middleware
      getter name : String
      getter builder : -> HTTP::Handler

      def initialize(klass)
        @name = klass.name.to_s
        @builder = -> { klass.new.as(HTTP::Handler) }
      end

      def ==(other : Middleware) : Bool
        name == other.name
      end

      def ==(other : Class) : Bool
        name == other.name.to_s
      end

      def inspect(io : IO) : IO
        io << name
      end

      def to_s(io : IO) : IO
        inspect(io)
      end

      def build_instance : HTTP::Handler
        @builder.call
      end
    end

    include Enumerable(Middleware)

    getter middlewares : Array(Middleware)

    def initialize
      @middlewares = [] of Middleware
    end

    def each(&)
      @middlewares.each { |m| yield m }
    end

    def size : Int32
      @middlewares.size
    end

    def last : Middleware
      @middlewares.last
    end

    def [](index : Int32) : Middleware
      @middlewares[index]
    end

    def use(klass) : self
      @middlewares.push(Middleware.new(klass))
      self
    end

    def unshift(klass) : self
      @middlewares.unshift(Middleware.new(klass))
      self
    end

    def insert(index : Int32, klass) : self
      @middlewares.insert(index, Middleware.new(klass))
      self
    end

    def insert_before(target : Middleware | Class, klass) : self
      insert(assert_index(target, "before"), klass)
    end

    def insert_after(target : Middleware | Class, klass) : self
      insert(assert_index(target, "after") + 1, klass)
    end

    def swap(target : Middleware | Class, klass) : self
      @middlewares[assert_index(target, "before")] = Middleware.new(klass)
      self
    end

    # Removes *target* if present; returns whether anything was removed
    # (Ruby returns the new array or nil — Bool here).
    def delete(target : Middleware | Class) : Bool
      before = @middlewares.size
      @middlewares.reject! { |m| m.name == target.name.to_s }
      @middlewares.size < before
    end

    def delete!(target : Middleware | Class) : self
      unless delete(target)
        raise "No such middleware to remove: #{target.name.to_s}"
      end
      self
    end

    def move_before(target : Middleware | Class, source : Middleware | Class) : self
      node = @middlewares.delete_at(assert_index(source, "before"))
      @middlewares.insert(assert_index(target, "before"), node)
      self
    end

    def move_after(target : Middleware | Class, source : Middleware | Class) : self
      node = @middlewares.delete_at(assert_index(source, "after"))
      @middlewares.insert(assert_index(target, "after") + 1, node)
      self
    end

    # Composes the chain (Rack `build(app)`): instantiates every node
    # and wires `HTTP::Handler#next` inward, returning the outermost
    # handler. Ruby passes the next middleware to the constructor;
    # Crystal's HTTP::Handler carries it as a `next` property.
    def build(app : HTTP::Handler) : HTTP::Handler
      handler = app
      @middlewares.reverse_each do |node|
        instance = node.build_instance
        instance.next = handler
        handler = instance
      end
      handler
    end

    private def assert_index(index : Int32, where : String) : Int32
      index
    end

    private def assert_index(target : Middleware | Class, where : String) : Int32
      name = target.name.to_s
      index = @middlewares.index { |m| m.name == name }
      raise "No such middleware to insert #{where}: #{name}" unless index
      index
    end
  end

  # The default-stack middlewares (CRails equivalents of Rails 8.1
  # classes, order mirrors default_stack_names from the oracle).
  module Middleware
    # Middlewares that need the owning application (config access)
    # include this; Application#middleware_chain injects itself while
    # composing the chain — the configuration-side equivalent of the
    # Rack `app` constructor argument. Keeps multiple app instances
    # (specs, tests) independent of the CRails.application global.
    module Configurable
      property application : CRails::Application?
    end

    # ActionDispatch::RequestId port: passes the incoming X-Request-Id
    # through verbatim (even non-UUID, as the oracle) or generates a
    # UUID v4 per request; echoes it on the response.
    class RequestId
      include HTTP::Handler

      def call(context : HTTP::Server::Context) : Nil
        rid = Observability.request_id(context)
        context.response.headers[Observability::REQUEST_ID_HEADER] = rid
        call_next(context)
      end
    end

    # Rails::Rack::Logger + LogSubscriber + Rack::Runtime port: the
    # Started/Completed lines (or the single JSON line in log_json
    # mode), X-Runtime, Prometheus metrics, the OTel server span.
    class RequestLogger
      include HTTP::Handler
      include Configurable

      def call(context : HTTP::Server::Context) : Nil
        rid = context.response.headers[Observability::REQUEST_ID_HEADER]? || "-"
        log_json = application.try(&.config.log_json) || false
        started = Time.instant
        unless log_json
          CRails.logger.info { Observability.log_started(rid, context) }
        end
        begin
          call_next(context)
        ensure
          elapsed = Time.instant - started
          status = context.response.status.code
          # Rack::Runtime format: "%.6f" % seconds (plain decimal, never
          # scientific notation).
          context.response.headers["X-Runtime"] = sprintf("%.6f", elapsed.total_seconds)
          Observability::METRICS.observe(context.request.method, status, elapsed.total_seconds)
          OTel.record_http_span(rid, context.request.method, context.request.path, status, elapsed.total_seconds)
          if log_json
            CRails.logger.info { Observability.log_json_entry(rid, context, status, elapsed.total_milliseconds) }
          else
            CRails.logger.info { Observability.log_completed(rid, status, elapsed.total_milliseconds) }
          end
        end
      end
    end

    # ActionDispatch::ShowExceptions + DebugExceptions port: the rescue
    # ladder — RoutingError -> 404 HTML page, TooManyRequests -> 429,
    # anything else -> 500 (backtrace in development).
    class ShowExceptions
      include HTTP::Handler

      NOT_FOUND_PAGE = "<!doctype html><html><body><h1>404 Not Found</h1></body></html>"

      def call(context : HTTP::Server::Context) : Nil
        call_next(context)
      rescue ex : ActionController::RoutingError
        context.response.status_code = 404
        context.response.headers["Content-Type"] = "text/html; charset=UTF-8"
        context.response.print NOT_FOUND_PAGE
      rescue ex : ActionController::TooManyRequests
        CRails.logger.warn { "#{context.request.method} #{context.request.path} rate limited (429)" }
        context.response.status_code = 429
        context.response.headers["Content-Type"] = "text/html; charset=utf-8"
      rescue ex : ActionController::MissingFile
        # ActionController::MissingFile -> 404, как rescue_responses Rails
        CRails.logger.info { "#{context.request.method} #{context.request.path} missing file (404)" }
        context.response.status_code = 404
        context.response.headers["Content-Type"] = "text/html; charset=UTF-8"
        context.response.print NOT_FOUND_PAGE
      rescue ex : ActionController::InvalidAuthenticityToken
        # CSRF: ActionController::InvalidAuthenticityToken -> 422, как
        # ShowExceptions в Rails (protect_from_forgery with: :exception).
        CRails.logger.warn { "#{context.request.method} #{context.request.path} can't verify CSRF token authenticity (422)" }
        context.response.status_code = 422
        context.response.headers["Content-Type"] = "text/html; charset=utf-8"
      rescue ex : ActionController::InvalidCrossOriginRequest
        # Кросс-доменный <script src=...> на защищённый JS-ответ -> 422.
        CRails.logger.warn { "#{context.request.method} #{context.request.path} cross-origin JavaScript blocked (422)" }
        context.response.status_code = 422
        context.response.headers["Content-Type"] = "text/html; charset=utf-8"
      rescue ex : ActionController::TypedParams::Invalid
        # TypedParams::Invalid -> 422 с телом ошибок в JSON (Iteration 10;
        # отклонение от Rails: ActionController::ParameterMissing -> 400
        # пустым телом, здесь типизированный API-контракт отвечает
        # машиной ошибок — как rswag/dry-validation convention).
        CRails.logger.info { "#{context.request.method} #{context.request.path} invalid params (422)" }
        context.response.status_code = 422
        context.response.headers["Content-Type"] = "application/json; charset=utf-8"
        context.response.print ex.to_json
      rescue ex : Exception
        # ActiveRecord::RecordNotFound -> 404, like Rails' rescue ladder.
        # Matched by name: railties_cr compiles also in apps without
        # active_record_cr, so the constant may not exist here.
        if ex.class.name == "ActiveRecord::RecordNotFound"
          CRails.logger.info { "#{context.request.method} #{context.request.path} not found (404)" }
          context.response.status_code = 404
          context.response.headers["Content-Type"] = "text/html; charset=UTF-8"
          context.response.print NOT_FOUND_PAGE
          return
        end
        CRails.logger.error(exception: ex) { "#{context.request.method} #{context.request.path} failed" }
        context.response.status_code = 500
        context.response.headers["Content-Type"] = "text/plain; charset=utf-8"
        body = "500 Internal Server Error"
        body += "\n#{ex}\n#{ex.backtrace?.try(&.join('\n'))}" if CRails.env.development?
        context.response.print body
      end
    end

    # Rack::Head port: dispatches HEAD as GET (routing sees GET) and
    # strips the response body — the discarded bytes never reach the
    # socket, and Content-Length comes out as 0 exactly like the Rails
    # 8.1 oracle (head_up_content_length).
    class Head
      include HTTP::Handler

      def call(context : HTTP::Server::Context) : Nil
        return call_next(context) unless context.request.method == "HEAD"

        context.request.method = "GET"
        original_output = context.response.output
        context.response.output = DiscardOutput.new
        begin
          call_next(context)
        ensure
          context.request.method = "HEAD"
          context.response.output = original_output
        end
      end

      # Drops bytes so the real output never writes headers mid-body;
      # after it is swapped back, close() computes Content-Length from
      # zero written bytes.
      private class DiscardOutput < IO
        def write(slice : Bytes) : Nil
        end

        def read(slice : Bytes) : NoReturn
          raise "Can't read from DiscardOutput"
        end

        def flush : Nil
        end

        def close : Nil
        end
      end
    end

    # Terminal handler: built-in endpoints (/up, /up.json, /metrics)
    # then routing + controller dispatch. In Rack terms this is the
    # Rails app object itself.
    class Dispatcher
      include HTTP::Handler

      def initialize(@application : CRails::Application)
      end

      def call(context : HTTP::Server::Context) : Nil
        rid = context.response.headers[Observability::REQUEST_ID_HEADER]?
        config = @application.config
        unless Observability.builtin?(context, @application.routes, rid, config.log_json)
          dispatch(context, rid, config)
        end
      end

      private def dispatch(context : HTTP::Server::Context, rid : String?, config : CRails::Config) : Nil
        match = @application.routes.match(request_method(context), context.request.path)
        # Dev endpoints (/rails/mailers etc., registered by framework
        # shards in CRails.dev_endpoints) — served only when the app
        # itself has no route for the path and show_previews is on
        # (development default; Rails: ActionMailer::Railtie routes).
        if !match && config.show_previews? &&
           (handler = CRails.dev_endpoint_for(context.request.path))
          handler.call(context)
          return
        end
        unless match
          raise ActionController::RoutingError.new(
            "No route matches #{context.request.method} #{context.request.path}")
        end
        klass = ActionController::Dispatch.resolve(match.route.controller)
        unless klass
          raise ActionController::RoutingError.new(
            "Unknown controller '#{match.route.controller}' (not registered at compile time)")
        end
        if rid && !config.log_json
          CRails.logger.info { Observability.log_processing(rid, match.route.controller, match.route.action, nil) }
        end
        controller = klass.new(context)
        controller.__set_params(match.params, match.route.controller, match.route.action)
        controller.__run_action(match.route.action)
      end

      # Rack::MethodOverride analog: forms tunnel PATCH/PUT/DELETE through
      # POST via a `_method` field (scaffold forms rely on it). The body is
      # peeked at and re-fed so the controller's own parsing still sees it.
      private def request_method(context : HTTP::Server::Context) : String
        return context.request.method unless context.request.method == "POST"
        ctype = context.request.headers["Content-Type"]? || ""
        return "POST" unless ctype.starts_with?("application/x-www-form-urlencoded")
        body = context.request.body.try(&.gets_to_end) || ""
        context.request.body = IO::Memory.new(body)
        if (m = body.match(/(?:^|&)_method=([^&]+)/))
          method = URI.decode_www_form(m[1]).upcase
          return method if {"PATCH", "PUT", "DELETE"}.includes?(method)
        end
        "POST"
      end
    end
  end
end
