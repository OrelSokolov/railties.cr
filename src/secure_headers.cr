# CRails::ContentSecurityPolicy — порт ActionDispatch::ContentSecurityPolicy
# (actionpack 8.1.4, action_dispatch/http/content_security_policy.rb) +
# secure default headers (config.action_dispatch.default_headers).
#
# Oracle: oracle/secure_headers_cases.rb → oracle/secure_headers_expected.yml
# (14 кейсов, сняты в rails 8.1.4 throwaway-app по стадиям — default/csp/
# mapping/report_only/override; стек гемa фиксируется при первом build,
# поэтому каждая стадия — отдельный процесс). Зеркало:
# spec/secure_headers_spec.cr.
#
# Ключевые факты оракула:
#   * дефолт-заголовки Rails 8.1 на любом ответе: X-Frame-Options
#     SAMEORIGIN, X-XSS-Protection "0", X-Content-Type-Options nosniff,
#     X-Permitted-Cross-Domain-Policies none, Referrer-Policy
#     strict-origin-when-cross-origin; Content-Security-Policy нет;
#   * директивы склеиваются "; " в порядке добавления (Ruby Hash —
#     insertion order), источники — " " ;
#   * маппинг символов: :self → 'self', :none → 'none', :unsafe_eval →
#     'unsafe-eval', :https → https:, :ws → ws: ...; строки — как есть;
#   * report_only=true → заголовок Content-Security-Policy-Report-Only
#     вместо Content-Security-Policy;
#   * override config.action_dispatch.default_headers из
#     config/application.rb побеждает дефолты.
#
# Отклонения от гема: nonce-генератор не портирован (нет request.env с
# сессией в middleware-слое — deviations см. middleware.cr); middleware
# ставит заголовки в ensure — 404/500 от ShowExceptions тоже получают
# secure-заголовки (в Rails это делает Response.default_headers). CSP не
# ставится на 304 (как в геме — nonces в кэше не совпали бы).

require "http/server/handler"

module CRails
  class ContentSecurityPolicy
    # MAPPINGS гема 1:1 (символ-источник → токен CSP).
    MAPPINGS = {
      "self"             => "'self'",
      "unsafe_eval"      => "'unsafe-eval'",
      "wasm_unsafe_eval" => "'wasm-unsafe-eval'",
      "unsafe_hashes"    => "'unsafe-hashes'",
      "unsafe_inline"    => "'unsafe-inline'",
      "none"             => "'none'",
      "http"             => "http:",
      "https"            => "https:",
      "data"             => "data:",
      "mediastream"      => "mediastream:",
      "allow_duplicates" => "'allow-duplicates'",
      "blob"             => "blob:",
      "filesystem"       => "filesystem:",
      "report_sample"    => "'report-sample'",
      "script"           => "'script'",
      "strict_dynamic"   => "'strict-dynamic'",
      "ws"               => "ws:",
      "wss"              => "wss:",
    }

    # DIRECTIVES гема 1:1 (имя метода → имя директивы CSP).
    DIRECTIVES = {
      "base_uri"                  => "base-uri",
      "child_src"                 => "child-src",
      "connect_src"               => "connect-src",
      "default_src"               => "default-src",
      "font_src"                  => "font-src",
      "form_action"               => "form-action",
      "frame_ancestors"           => "frame-ancestors",
      "frame_src"                 => "frame-src",
      "img_src"                   => "img-src",
      "manifest_src"              => "manifest-src",
      "media_src"                 => "media-src",
      "object_src"                => "object-src",
      "prefetch_src"              => "prefetch-src",
      "require_trusted_types_for" => "require-trusted-types-for",
      "script_src"                => "script-src",
      "script_src_attr"           => "script-src-attr",
      "script_src_elem"           => "script-src-elem",
      "style_src"                 => "style-src",
      "style_src_attr"            => "style-src-attr",
      "style_src_elem"            => "style-src-elem",
      "trusted_types"             => "trusted-types",
      "worker_src"                => "worker-src",
    }

    getter directives : Array({String, Array(String)})

    def initialize
      # insertion order, как Ruby Hash в геме (build склеивает в порядке
      # добавления)
      @directives = [] of {String, Array(String)}
    end

    def initialize(&block : self ->)
      @directives = [] of {String, Array(String)}
      yield self
    end

    {% for name, directive in DIRECTIVES %}
      def {{name.id}}(*sources : String | Symbol) : Nil
        set_directive({{directive}}, sources.to_a)
      end
    {% end %}

    def block_all_mixed_content(enabled : Bool = true) : Nil
      if enabled
        set_flag("block-all-mixed-content")
      else
        delete("block-all-mixed-content")
      end
    end

    def sandbox(*values : String) : Nil
      set_directive("sandbox", values.to_a)
    end

    def sandbox(enabled : Bool = true) : Nil
      if enabled
        set_flag("sandbox")
      else
        delete("sandbox")
      end
    end

    def report_uri(uri : String) : Nil
      set_directive("report-uri", [uri])
    end

    def build : String
      # flag-директивы (sandbox без значений, block-all-mixed-content) —
      # только имя, без хвостового пробела
      @directives.map do |directive, sources|
        sources.empty? ? directive : "#{directive} #{sources.join(' ')}"
      end.join("; ")
    end

    private def set_directive(name : String, sources : Array(String | Symbol)) : Nil
      delete(name)
      @directives << {name, sources.map { |s| apply_mapping(s) }}
    end

    private def set_flag(name : String) : Nil
      delete(name)
      @directives << {name, [] of String}
    end

    private def delete(name : String) : Nil
      @directives.reject! { |directive, _| directive == name }
    end

    private def apply_mapping(source : String | Symbol) : String
      MAPPINGS[source.to_s]? || source.to_s
    end
  end

  module Middleware
    # ActionDispatch::ContentSecurityPolicy::Middleware +
    # config.action_dispatch.default_headers: ставит дефолт-заголовки и
    # CSP (или CSP-Report-Only) на ответ, не перезаписывая то, что уже
    # выставил контроллер. Внутри ensure: ответы, сформированные
    # ShowExceptions (404/500), тоже получают заголовки — в Rails это
    # делает ActionDispatch::Response через default_headers.
    class ContentSecurityPolicy
      include HTTP::Handler
      include Configurable

      HEADER                = "Content-Security-Policy"
      REPORT_ONLY_HEADER    = "Content-Security-Policy-Report-Only"

      def call(context : HTTP::Server::Context) : Nil
        call_next(context)
      ensure
        config = application.try(&.config)
        unless config.nil?
          apply_default_headers(context, config)
          apply_csp(context, config)
        end
      end

      private def apply_default_headers(context : HTTP::Server::Context,
                                        config : CRails::Config) : Nil
        config.default_headers.each do |name, value|
          context.response.headers[name] = value unless context.response.headers[name]?
        end
      end

      private def apply_csp(context : HTTP::Server::Context,
                            config : CRails::Config) : Nil
        # Гем не ставит CSP на 304: nonces новой политики могут не
        # совпасть с закэшированным HTML.
        return if context.response.status.code == 304
        policy = config.content_security_policy
        return if policy.nil?
        return if context.response.headers[HEADER]? ||
                  context.response.headers[REPORT_ONLY_HEADER]?
        name = config.content_security_policy_report_only? ? REPORT_ONLY_HEADER : HEADER
        context.response.headers[name] = policy.build
      end
    end
  end
end
