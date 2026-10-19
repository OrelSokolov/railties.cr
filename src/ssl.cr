# CRails::Middleware::SSL + AssumeSSL — port of ActionDispatch::SSL /
# ActionDispatch::AssumeSSL (Rails 8.1.4): TLS redirect, secure cookie
# flagging, HSTS. Oracle: oracle/ssl_expected.yml (captured from a real
# 8.1.4 app, oracle/ssl_cases.rb); mirrored in spec/ssl_spec.cr.
#
# Deviations from the gem (asserted in the spec footer):
# - both middlewares are always in the default stack and read
#   config.force_ssl / config.assume_ssl at call time (CRails composes
#   the chain before environments/*.cr run); with the flags off they
#   are no-ops — Rails skips inserting them entirely, observable only
#   via `crails middleware` listing;
# - config.ssl_options is a typed CRails::SSLOptions object instead of
#   a Hash (redirect/hsts become nested objects; `redirect.enabled? =
#   false` == the gem's `redirect: false`, `hsts.expires = 0` ==
#   `hsts: false` — the max-age=0 header is still sent, like the gem);
# - ssl detection is X-Forwarded-Proto based (Rack reads the env's
#   url_scheme / HTTPS, set by the frontend server or AssumeSSL): a
#   directly TLS-serving process has no request-level scheme marker in
#   Crystal's HTTP::Server, so put a proxy in front or use assume_ssl;
# - AssumeSSL sets the X-Forwarded-Proto/Port request headers (the
#   Crystal carrier for what the gem writes into the rack env);
# - redirect body is a String (the gem's Array body), HSTS/cookie
#   flagging applies to buffered responses only (same window as the
#   other CRails response-rewriting middlewares).

require "./middleware"

module CRails
  # config.ssl_options — typed port of the Rails options Hash.
  #
  #   config.force_ssl = true
  #   config.ssl_options.redirect.host = "secure.example.com"
  #   config.ssl_options.redirect.port = 8080
  #   config.ssl_options.hsts.expires = 3600
  #   config.ssl_options.hsts.subdomains = false
  #   config.ssl_options.hsts.preload = true
  class SSLOptions
    class Redirect
      attr_accessor host : String?
      attr_accessor port : Int32?
      attr_accessor status : Int32?
      attr_accessor body : String?
      # redirect: false — no redirecting and no cookie flagging (the
      # gem's exclude falls back to `!@redirect`).
      property? enabled : Bool = true
      attr_accessor exclude : (HTTP::Server::Context -> Bool)?
    end

    class HSTS
      # 2 years, as recommended on hstspreload.org (the gem default).
      attr_accessor expires : Int64 = 63072000_i64
      property? subdomains : Bool = true
      property? preload : Bool = false
    end

    attr_reader redirect : Redirect = Redirect.new
    attr_reader hsts : HSTS = HSTS.new
    property? secure_cookies : Bool = true

    # config.ssl_options = { redirect: false } analog (DSL shortcut).
    def redirect=(enabled : Bool) : Nil
      @redirect.enabled = enabled
    end

    # config.ssl_options = { hsts: false } analog: the header is still
    # sent with max-age=0 to expire the browser's cached setting.
    def hsts=(enabled : Bool) : Nil
      @hsts.expires = 0_i64 unless enabled
    end

    def hsts_header : String
      value = "max-age=#{hsts.expires}"
      value += "; includeSubDomains" if hsts.subdomains?
      value += "; preload" if hsts.preload?
      value
    end
  end

  module Middleware
    # ActionDispatch::SSL port: permanently redirects http:// to
    # https://, flags response cookies as secure and sets HSTS on
    # secure responses. Active only when config.force_ssl.
    class SSL
      include HTTP::Handler
      include Configurable

      PERMANENT_REDIRECT_REQUEST_METHODS = %w[GET HEAD]

      def call(context : HTTP::Server::Context) : Nil
        cfg = application.try(&.config)
        return call_next(context) unless cfg.try(&.force_ssl)

        options = cfg.not_nil!.ssl_options
        if SSL.ssl_request?(context.request)
          call_next(context)
          response = context.response
          set_hsts_header(response, options)
          flag_cookies_as_secure!(response) if options.secure_cookies? && !excluded?(options, context)
        elsif excluded?(options, context)
          call_next(context)
        else
          redirect_to_https(context, options)
        end
      end

      # A request counts as secure when the frontend (or AssumeSSL)
      # forwarded proto https — the last entry of the chain wins.
      def self.ssl_request?(request : HTTP::Request) : Bool
        proto = request.headers["X-Forwarded-Proto"]?
        return false unless proto
        proto.split(',').map(&.strip).last? == "https"
      end

      private def excluded?(options : SSLOptions, context : HTTP::Server::Context) : Bool
        # redirect: false excludes everything, like the gem's
        # `@exclude = ... || proc { !@redirect }`.
        return true unless options.redirect.enabled?
        options.redirect.exclude.try(&.call(context)) || false
      end

      private def set_hsts_header(response : HTTP::Server::Response, options : SSLOptions) : Nil
        response.headers["Strict-Transport-Security"] ||= options.hsts_header
      end

      private def redirect_to_https(context : HTTP::Server::Context, options : SSLOptions) : Nil
        request = context.request
        response = context.response
        response.status_code = options.redirect.status || redirection_status(request)
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        response.headers["Location"] = https_location_for(request, options)
        response.print options.redirect.body if options.redirect.body
      end

      # GET/HEAD redirect permanently (301); other methods preserve the
      # request method — 308 by default in Rails 8.1
      # (config.action_dispatch.ssl_default_redirect_status).
      private def redirection_status(request : HTTP::Request) : Int32
        if PERMANENT_REDIRECT_REQUEST_METHODS.includes?(request.method)
          301
        else
          application.try(&.config.ssl_default_redirect_status) || 307
        end
      end

      private def https_location_for(request : HTTP::Request, options : SSLOptions) : String
        host = options.redirect.host || request_host(request)
        port = options.redirect.port || request_port(request)

        String.build do |io|
          io << "https://" << host
          io << ":" << port if port && port != 80 && port != 443
          io << request.path
          io << "?" << request.query if query = request.query.presence
        end
      end

      private def request_host(request : HTTP::Request) : String
        header = request.headers["Host"]? || ""
        return header if header.empty?
        if header.starts_with?('[')
          "#{header.split(']', 2)[0]?}]" # "[::1]:3000" -> "[::1]"
        elsif (idx = header.rindex(':')) && header[(idx + 1)..].matches?(/\A\d+\z/)
          header[0...idx]
        else
          header
        end
      end

      private def request_port(request : HTTP::Request) : Int32?
        header = request.headers["Host"]? || ""
        return nil if header.empty?
        if header.starts_with?('[')
          return nil unless header.includes?(']')
          tail = header.split(']', 2)[1]? || ""
          tail[1..].to_i? if tail.starts_with?(':')
        elsif (idx = header.rindex(':')) && header[(idx + 1)..].matches?(/\A\d+\z/)
          header[(idx + 1)..].to_i
        end
      end

      # Appends "; secure" to every Set-Cookie that lacks the flag.
      # HTTP::Headers#get? casts a single stored value into a fresh
      # array, so the flagged cookies are written back explicitly.
      private def flag_cookies_as_secure!(response : HTTP::Server::Response) : Nil
        cookies = response.headers.get?("Set-Cookie")
        return unless cookies

        flagged = cookies.map do |cookie|
          cookie.matches?(/;\s*secure\s*(;|$)/i) ? cookie : "#{cookie}; secure"
        end
        response.headers.delete("Set-Cookie")
        flagged.each { |cookie| response.headers.add("Set-Cookie", cookie) }
      end
    end

    # ActionDispatch::AssumeSSL port: for proxies that terminate SSL
    # without forwarding proto headers — makes the request look https
    # to everything downstream (SSL middleware, url generation).
    # Active only when config.assume_ssl (read at call time).
    class AssumeSSL
      include HTTP::Handler
      include Configurable

      def call(context : HTTP::Server::Context) : Nil
        unless application.try(&.config.assume_ssl)
          call_next(context)
          return
        end
        context.request.headers["X-Forwarded-Proto"] = "https"
        context.request.headers["X-Forwarded-Port"] = "443"
        call_next(context)
      end
    end
  end
end
