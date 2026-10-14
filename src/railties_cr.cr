require "log"
require "http"
require "action_pack_cr"
require "importmap_cr"
require "propshaft_cr"
require "./observability"
require "./credentials"
require "./middleware"
require "./host_authorization"
require "./ssl"
require "./secure_headers"
require "./static"
require "./propshaft_helper"
require "./nodelay_server"
require "./vite_dev"
require "./testing/integration"
require "./otel"

# Importmap (pin/pin_all_from) — хелперы доступны всем вьюхам приложения
# (контроллер и есть view-контекст в crails).
class ActionController::Base
  include Importmap::ImportmapTagsHelper
end

# CRails — the `Rails` module equivalent (the `CRails` namespace is the
# only intentional 1:1 difference, see ../PLAN.md).
module CRails
  VERSION = "0.1.0"

  enum Env
    Development
    Test
    Production

    def development? : Bool
      self == Development
    end

    def test? : Bool
      self == Test
    end

    def production? : Bool
      self == Production
    end

    # Rails.env.local? — development/test (tmp/local_secret.txt fallback).
    def local? : Bool
      development? || test?
    end
  end

  @@application : Application?
  @@env : Env?
  @@root : String?
  @@logger : Log?

  def self.application : Application
    @@application.not_nil!
  end

  def self.application=(app : Application) : Application
    @@application = app
  end

  def self.env : Env
    @@env ||= begin
      raw = (ENV["CRAILS_ENV"]? || ENV["RAILS_ENV"]? || "development").downcase.tr("-", "_")
      Env.parse?(raw) || Env::Development
    end
  end

  def self.root : String
    @@root ||= ENV["CRAILS_ROOT"]? || Dir.current
  end

  # Тестовый хук: смена корня приложения (сбрасывает memo credentials).
  def self.root=(path : String) : String
    @@root = path
    @@credentials = nil
    path
  end

  # Тестовый хук: смена env (сбрасывает memo credentials — резолв путей
  # зависит от env, см. CRails.credentials_paths).
  def self.env=(value : Env) : Env
    @@env = value
    @@credentials = nil
    value
  end

  def self.logger : Log
    # The default root binding (stderr, info) is used; no extra binding
    # or messages get logged twice.
    @@logger ||= Log.for("crails")
  end

  @@dev_endpoints : Hash(String, Proc(HTTP::Server::Context, Bool))?

  # Dev-only endpoints mounted by framework shards or app glue — the
  # analog of framework railties drawing routes (railties_cr does not
  # depend on action_mailer_cr, so action_mailer's /rails/mailers
  # previews UI registers itself here at require time). Path prefix →
  # handler returning true when it handled the request; served instead
  # of routing when config.show_previews (development default), and
  # only when the app itself has no route for the path.
  def self.dev_endpoints : Hash(String, Proc(HTTP::Server::Context, Bool))
    @@dev_endpoints ||= {} of String => Proc(HTTP::Server::Context, Bool)
  end

  # Longest matching prefix wins (exact match beats a longer path).
  def self.dev_endpoint_for(path : String) : Proc(HTTP::Server::Context, Bool)?
    dev_endpoints.each do |prefix, handler|
      return handler if path == prefix || path.starts_with?("#{prefix}/")
    end
    nil
  end

  class Config
    property host : String = "localhost"
    property port : Int32 = 3000
    # JSON request logs: CRails extension (Rails 8 ships no JSON log
    # formatter); on by default in production like Rails' JSON-ish prod
    # logging posture, text lines elsewhere. CRAILS_LOG_JSON=1 forces
    # JSON in any env (ops/bench knob).
    def initialize
      @log_json = CRails.env.production? || ENV["CRAILS_LOG_JSON"]? == "1"
      # Default middleware stack (Rails 8.1 order for the pieces CRails
      # ships; the full Rails list is in oracle/middleware_expected.yml,
      # default_stack_names). Apps mutate it freely in config/*.cr via
      # use/insert_before/insert_after/swap/delete.
      @middleware = CRails::MiddlewareStack.new
      # HostAuthorization → AssumeSSL → SSL — первые в стеке, как в Rails
      # 8.1 (Sendfile между ними в CRails нет). Узлы всегда в стеке и
      # читают config.hosts / assume_ssl / force_ssl на call-time
      # (environments/*.cr грузятся после сборки стека); при выключенных
      # флагах / пустых hosts — no-op (Rails такие узлы вовсе не
      # вставляет — отклонение видно только в `crails middleware`).
      @middleware.use CRails::Middleware::HostAuthorization
      @middleware.use CRails::Middleware::AssumeSSL
      @middleware.use CRails::Middleware::SSL
      # Vite dev-прокси (CRails-расширение поверх vite_ruby 3.9.2
      # DevServerProxy) — только в dev-режиме (или CRAILS_VITE_DEV=1),
      # до Static: пока манифеста нет, entrypoints/ассеты отдаёт
      # vite-сервер; HMR-ws сплайсится там же.
      if CRails.env.development? || ENV["CRAILS_VITE_DEV"]? == "1"
        @middleware.use CRails::Middleware::ViteDevProxy
      end
      # Static (порт ActionDispatch::Static) — первым, как в Rails 8.1;
      # раздаёт public/ (включая vite-ассеты с immutable-кэшем).
      @middleware.use CRails::Middleware::Static
      @middleware.use CRails::Middleware::RequestId
      @middleware.use CRails::Middleware::RequestLogger
      # Secure headers + CSP: до ShowExceptions, чтобы ответы 404/500
      # тоже получали заголовки (в Rails их ставит Response.default_headers)
      @middleware.use CRails::Middleware::ContentSecurityPolicy
      @middleware.use CRails::Middleware::ShowExceptions
      @middleware.use CRails::Middleware::Head
    end

    property log_json : Bool
    property? metrics : Bool = true

    # config.hosts — ActionDispatch::HostAuthorization записи: строка
    # ("example.com", ".example.com", "example.com:3000"), Regex или
    # IPCidr ("192.168.0.0/16"). В development — дефолт Rails 8.1:
    # .localhost/.test + любые IP; CRAILS_DEVELOPMENT_HOSTS (или
    # RAILS_DEVELOPMENT_HOSTS, запятая) добавляет свои.
    property hosts : Array(Middleware::HostEntry) = begin
      if CRails.env.development?
        dev = [".localhost", ".test"] of Middleware::HostEntry +
          [Middleware::IPCidr.new("0.0.0.0/0"), Middleware::IPCidr.new("::/0")]
        extra = (ENV["CRAILS_DEVELOPMENT_HOSTS"]? || ENV["RAILS_DEVELOPMENT_HOSTS"]? || "")
          .split(',').map(&.strip).reject(&.empty?)
        dev.concat(extra)
      else
        [] of Middleware::HostEntry
      end
    end

    # config.host_authorization = { exclude: / response_app: } —
    # типизированные свойства (отклонение: нет Hash-опций).
    property host_authorization_exclude : (HTTP::Server::Context -> Bool)?
    property host_authorization_response_app : Proc(HTTP::Server::Context, Nil)?

    # config.force_ssl / assume_ssl / ssl_options — ActionDispatch::SSL
    # и AssumeSSL (см. src/ssl.cr). ssl_default_redirect_status: 308 —
    # дефолт Rails 8.1 (config.action_dispatch.ssl_default_redirect_status).
    property force_ssl : Bool = false
    property assume_ssl : Bool = false
    property ssl_options : CRails::SSLOptions = CRails::SSLOptions.new
    property ssl_default_redirect_status : Int32 = 308

    # config.action_mailer.show_previews: /rails/mailers (and any other
    # registered CRails.dev_endpoints) is served in development only,
    # like Rails 8.1's default.
    property? show_previews : Bool = CRails.env.development?
    getter middleware : CRails::MiddlewareStack

    # config.action_dispatch.default_headers (Rails 8.1 defaults 1:1).
    # Ставятся на каждый ответ, если контроллер не выставил своё.
    property default_headers : Hash(String, String) = {
      "X-Frame-Options"                   => "SAMEORIGIN",
      "X-XSS-Protection"                  => "0",
      "X-Content-Type-Options"            => "nosniff",
      "X-Permitted-Cross-Domain-Policies" => "none",
      "Referrer-Policy"                   => "strict-origin-when-cross-origin",
    }

    @content_security_policy : CRails::ContentSecurityPolicy?

    # config.content_security_policy (блок-DSL как в Rails; nil — политики
    # нет, заголовок не ставится).
    def content_security_policy : CRails::ContentSecurityPolicy?
      @content_security_policy
    end

    def content_security_policy(& : CRails::ContentSecurityPolicy ->) : Nil
      policy = CRails::ContentSecurityPolicy.new
      yield policy
      @content_security_policy = policy
    end

    def content_security_policy=(policy : CRails::ContentSecurityPolicy?) : Nil
      @content_security_policy = policy
    end

    # config.content_security_policy_report_only
    property? content_security_policy_report_only : Bool = false

    # config.assets.* — Propshaft-модель (порты дефолтов Propshaft::Railtie:
    # app/assets/* + vendor-каталоги; prefix /assets; version "1";
    # компиляторы css/js url-rewrite + sourceMappingURL). Прекомпрессия
    # versions = [".gz", ".br"] — CRails-расширение (static.cr отдаёт
    # соседи по Accept-Encoding; гем ничего подобного не пишет).
    property assets : Propshaft::Config = begin
      assets = Propshaft::Config.new
      assets.versions = [".gz", ".br"]
      assets
    end

    # Дефолтные load path: подкаталоги app/assets/* (аналог
    # paths["app/assets"].existent_directories в railtie гема) +
    # vendor/assets/* + vendor/javascript (importmap-пины). Вызывается
    # лениво из Application#assets — конфиги приложения успевают
    # дописать config.assets.paths до первого обращения.
    def default_asset_paths : Array(String)
      paths = (Dir.glob(File.join(CRails.root, "app/assets/*")) +
               Dir.glob(File.join(CRails.root, "vendor/assets/*")) +
               [File.join(CRails.root, "vendor/javascript")])
        .select { |d| Dir.exists?(d) }
        .map { |d| d[(CRails.root.size + 1)..] }
      paths.uniq
    end
  end

  class Application
    getter routes : CRails::Routes::RouteSet
    getter config : CRails::Config
    getter? initialized = false
    @middleware_chain : HTTP::Handler?

    def initialize
      @routes = CRails::Routes::RouteSet.new
      @config = CRails::Config.new
    end

    # Сборка ассетов (аналог Rails.application.assets): load path из
    # config.assets.paths (дефолты — app/assets/* + vendor), резолвер —
    # Static при существующем манифесте, иначе Dynamic (dev).
    def assets : Propshaft::Assembly
      @assets ||= begin
        config.assets.paths = default_asset_paths if config.assets.paths.empty?
        Propshaft::Assembly.new(config.assets)
      end
    end

    @assets : Propshaft::Assembly?

    def initialize! : self
      @initialized = true
      CRails.apply_secret_key_base!
      # OpenAPI-документ строится из таблицы роутов (Iteration 10).
      ::CRails::OpenAPI.routes = @routes
      self
    end

    # config/credentials.yml.enc + config/master.key (см. credentials.cr)
    def credentials : CRails::EncryptedConfiguration
      @credentials ||= CRails.credentials
    end

    # HTTP entry point: the middleware stack (config.middleware) with
    # routing dispatch as the terminal handler.
    def call(context : HTTP::Server::Context) : Nil
      middleware_chain.call(context)
    end

    # The composed handler chain — built once, on first use. Middleware
    # added after the first request takes no effect (same as Rails:
    # config.middleware mutations happen at boot time only).
    def middleware_chain : HTTP::Handler
      @middleware_chain ||= begin
        head = config.middleware.build(Middleware::Dispatcher.new(self))
        node = head
        while node.is_a?(HTTP::Handler)
          if node.is_a?(Middleware::Configurable)
            node.application = self
          end
          node = node.next
        end
        # Cable-монтаж перед всем стеком: WebSocket-upgrade на /cable не
        # должен попадать в request-логирование и парсинг тела (аналог
        # ActionCable::Engine, чей route замыкается на сервер напрямую).
        if cable = cable_handler
          cable.next = head
          cable
        else
          head
        end
      end
    end

    # --- built-in server binary commands (bin/app serve|routes|bot:poll) ---

    def boot(argv : Array(String)) : Nil
      case argv[0]? || "serve"
      when "serve" then serve(argv.skip(1)) # skip(1), not [1..]: [][1..] raises
      when "routes" then print_routes
      when "middleware" then print_middleware
      when "credentials:show" then cmd_credentials_show(argv.skip(1))
      when "credentials:edit" then cmd_credentials_edit(argv.skip(1))
      when "secret" then puts Random::Secure.hex(64)
      when "bot:poll"
        platform = argv[1]? || "telegram"
        if poller = bot_poller
          STDERR.puts "ActionBot: polling #{platform} (Ctrl-C to stop)"
          poller.call(platform)
        else
          STDERR.puts "No bots compiled in (app/bots/** defines them; " \
                      "crails generate bot adds the wiring)"
          exit 1
        end
      when "worker"
        if hook = worker
          STDERR.puts "CRails worker role: running app worker (Ctrl-C to stop)"
          hook.call
        else
          STDERR.puts "CRails_ROLE_NOT_COMPILED: no worker compiled in " \
                      "(set CRails.application.worker in src/app.cr, e.g. a Kiq/SolidQueue launcher)"
          exit 3
        end
      when "scheduler"
        if hook = scheduler
          STDERR.puts "CRails scheduler role: running app scheduler (Ctrl-C to stop)"
          hook.call
        else
          STDERR.puts "CRails_ROLE_NOT_COMPILED: no scheduler compiled in " \
                      "(set CRails.application.scheduler in src/app.cr)"
          exit 3
        end
      else
        STDERR.puts "Usage: app [serve] [worker] [scheduler] [routes] [middleware] [bot:poll PLATFORM] [-p PORT] [-b HOST]"
        exit 1
      end
    end

    # Set by the app's app/bots/** glue (`bin/app bot:poll telegram`);
    # keeps railties free of an action_bot dependency.
    property bot_poller : Proc(String, Nil)? = nil

    # Роли процессов (bin/app worker / bin/app scheduler): хук задаётся
    # glue-кодом приложения в src/app.cr (например, Kiq::Launcher или
    # SolidQueue-воркер) — railties не зависит от очередей.
    property worker : Proc(Nil)? = nil
    property scheduler : Proc(Nil)? = nil

    # Cable-монтаж (аналог ActionCable::Engine: /cable в общем стеке).
    # railties не зависит от action_cable_cr — приложение с кабелем
    # подставляет готовый HTTP::Handler (обычно ActionCable::Server#
    # ws_handler); он встаёт ПЕРЕД middleware-стеком, чтобы upgrade-
    # запросы не проходили RequestId/Logger и не разбирали тело.
    property cable_handler : HTTP::Handler? = nil

    private def serve(args : Array(String)) : Nil
      port = config.port
      host = config.host
      i = 0
      while i < args.size
        case args[i]
        when "-p", "--port" then port = args[i + 1].to_i; i += 2
        when "-b", "--bind" then host = args[i + 1]; i += 2
        when "-e", "--env"  then i += 2 # env already comes via CRAILS_ENV
        else
          STDERR.puts "Unknown option: #{args[i]}"
          exit 1
        end
      end
      # TCP_NODELAY на сокетах (CRails::TcpNodelayServer): без него
      # крупные ответы (несколько чанк-write) ловят Nagle/delayed-ACK
      # сталл ~40ms на запрос — см. nodelay_server.cr. Так же поступают
      # nginx (tcp_nodelay on) и Puma.
      server = CRails::TcpNodelayServer.new do |context|
        CRails.application.call(context)
      end
      middleware_chain # compose before listening: no first-request race
      reuse_port = ENV["CRAILS_REUSE_PORT"]? == "1"
      address = server.bind_tcp(host, port, reuse_port: reuse_port)
      write_pidfile
      # Graceful shutdown: stop accepting, let in-flight requests
      # finish, exit 0. With CRAILS_REUSE_PORT=1 a replacement process
      # binds the same port first, giving zero-downtime restarts.
      shutdown = ->(signal : Signal) do
        CRails.logger.info { "SIG#{signal} received, shutting down gracefully" }
        spawn do
          server.close
          # Give in-flight requests a moment to drain, then exit.
          sleep 2.seconds
          exit 0
        end
      end
      Signal::INT.trap { shutdown.call(Signal::INT) }
      Signal::TERM.trap { shutdown.call(Signal::TERM) }
      CRails.logger.info { "CRails #{VERSION} (#{CRails.env}) listening on http://#{address}#{" (reuse_port)" if reuse_port}" }
      server.listen
      # server.listen returns once the server is closed: drain is done.
      CRails.logger.info { "server drained, bye" }
      delete_pidfile
    end

    private def write_pidfile : Nil
      dir = File.join(CRails.root, "tmp", "pids")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "app.pid"), Process.pid.to_s)
    rescue File::Error
      # read-only FS or missing tmp/: pidfile is best-effort
    end

    private def delete_pidfile : Nil
      File.delete(File.join(CRails.root, "tmp", "pids", "app.pid"))
    rescue File::Error
    end

    # `--environment ENV` / `-e ENV` (гем: EnvironmentArgument; без
    # значения опция игнорируется).
    private def extract_credentials_env(args : Array(String)) : String?
      i = 0
      while i < args.size
        case args[i]
        when "--environment", "-e" then return args[i + 1]?
        when .starts_with?("--environment=")  then return args[i].split('=', 2)[1]?
        end
        i += 1
      end
      nil
    end

    # show: резолв путей для env с fallback на глобальные (гем:
    # load_environment_config! меняет Rails.env → credentials_defaults).
    private def credentials_for(env : String?) : CRails::EncryptedConfiguration
      return credentials unless env
      content_path, key_path = CRails.credentials_paths(env)
      CRails::EncryptedConfiguration.new(content_path, key_path,
        raise_if_missing_key: false)
    end

    private def relative_creds_path(path : String) : String
      root = CRails.root
      path.starts_with?("#{root}/") ? path[(root.size + 1)..] : path
    end

    private def missing_credentials!(creds : CRails::EncryptedConfiguration) : Nil
      unless creds.key?
        STDERR.puts "Missing '#{relative_creds_path(creds.key_path)}' to decrypt credentials. See `crails credentials:edit --help`."
      else
        STDERR.puts "File '#{relative_creds_path(creds.content_path)}' does not exist. Use `crails credentials:edit` to change that."
      end
      exit 1
    end

    private def wrong_key_message(path : String?) : Nil
      STDERR.puts "Couldn't decrypt #{path || "credentials"}. Perhaps you passed the wrong key?"
    end

    private def cmd_credentials_show(args : Array(String)) : Nil
      creds = credentials_for(extract_credentials_env(args))
      display_path = relative_creds_path(creds.content_path)
      content = creds.read
      return missing_credentials!(creds) if content.blank?
      puts content
    rescue ex : CRails::EncryptedConfiguration::MissingKeyError
      STDERR.puts ex.message
      exit 1
    rescue ex : ActiveSupport::MessageEncryptor::InvalidMessage
      wrong_key_message(display_path)
      exit 1
    end

    private def cmd_credentials_edit(args : Array(String)) : Nil
      env = extract_credentials_env(args)
      # edit: принудительные env-пути, без fallback (как в геме)
      creds = env ? CRails.env_credentials(env) : credentials
      display_path = relative_creds_path(creds.content_path)

      # ensure_encryption_key_has_been_added / ensure_credentials_have_been_added
      unless creds.key?
        Dir.mkdir_p(File.dirname(creds.key_path))
        File.write(creds.key_path, Random::Secure.hex(16) + "\n")
        STDERR.puts "Adding '#{relative_creds_path(creds.key_path)}' to store the encryption key."
      end
      unless File.exists?(creds.content_path)
        Dir.mkdir_p(File.dirname(creds.content_path))
        # dev/test env-credentials создаются без secret_key_base (гем:
        # skip_secret_key_base) — там секрет берётся из tmp/local_secret.txt
        content = env && env.in?("development", "test") ? "" : "secret_key_base: #{Random::Secure.hex(64)}\n"
        creds.write(content)
      end

      # VISUAL имеет приоритет над EDITOR (гем: Helpers::Editor)
      editor = ENV["VISUAL"]?.try(&.presence) || ENV["EDITOR"]?.try(&.presence)
      if editor.nil?
        STDERR.puts "No $VISUAL or $EDITOR to open file in. Assign one like this:"
        STDERR.puts ""
        STDERR.puts %(VISUAL="code --wait" crails credentials:edit)
        STDERR.puts ""
        STDERR.puts "For editors that fork and exit immediately, it's important to pass a wait flag;"
        STDERR.puts "otherwise, the file will be saved immediately with no chance to edit."
        return
      end

      puts "Editing #{display_path}..."
      creds.change { |tmp_path| Process.run("sh", ["-c", "#{editor} #{tmp_path}"]) }
      puts "File encrypted and saved."
      warn_if_credentials_invalid(creds)
    rescue ex : CRails::EncryptedConfiguration::MissingKeyError
      STDERR.puts ex.message
      exit 1
    rescue ex : ActiveSupport::MessageEncryptor::InvalidMessage
      wrong_key_message(display_path)
      exit 1
    end

    private def warn_if_credentials_invalid(creds : CRails::EncryptedConfiguration) : Nil
      YAML.parse(creds.read)
    rescue ex : YAML::Error
      STDERR.puts "WARNING: Invalid YAML in '#{relative_creds_path(creds.content_path)}'."
      STDERR.puts ""
      STDERR.puts "Your application will not be able to load '#{relative_creds_path(creds.content_path)}' until the error has been fixed."
    end

    def print_routes : Nil
      printf("%-12s %-7s %-24s %s\n", "Prefix", "Verb", "URI Pattern", "Controller#Action")
      routes.routes.each do |route|
        printf("%-12s %-7s %-24s %s#%s\n",
          route.name || "", route.verb, route.pattern, route.controller, route.action)
      end
    end

    # `rake middleware` equivalent: the effective stack, "use NAME" per line.
    def print_middleware(io : IO = STDOUT) : Nil
      config.middleware.each { |m| io << "use " << m.name << '\n' }
    end
  end
end

# Относительные dir в pin_all_from резолвятся от корня приложения
# (аналог Rails.root в геме).
Importmap::Map.root = CRails.root
