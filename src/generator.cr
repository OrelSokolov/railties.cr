require "file_utils"
require "random/secure"

module CRails
  module Generators
    # `crails new APP_PATH` — generates the Iteration 0 app skeleton.
    class App
      def self.run(path : String) : Nil
        new(path).run
      end

      def initialize(@path : String)
        @name = File.basename(File.expand_path(@path))
      end

      def run : Nil
        dir = File.expand_path(@path)
        abort "ERROR: #{dir} already exists" if File.exists?(dir)

        exe = Process.executable_path || abort("ERROR: cannot locate the crails binary")
        railties_dir = File.dirname(File.dirname(exe)) # railties.cr/
        repo_root = File.dirname(railties_dir)          # monorepo root
        rel = Path[repo_root].relative_to?(Path[dir]) ||
          abort("ERROR: cannot compute relative path from #{dir} to #{repo_root}")

        puts "      create  #{@path}"
        dirs = [
          "src", "config/environments", "config/initializers", "app/controllers", "app/models",
          "app/views/layouts", "app/views/welcome", "app/javascript",
          "db", "public", "bin", "lib",
        ]
        dirs.each { |d| FileUtils.mkdir_p(File.join(dir, d)) }

        # Framework shards are wired as lib/ symlinks into the monorepo
        # (dev mode): shards treats duplicate path deps across the graph
        # as ambiguous sources, so the app's shard.yml stays free of
        # framework dependencies.
        {"active_support.cr", "action_view.cr", "action_pack.cr",
         "active_record.cr", "railties.cr", "importmap.cr"}.each do |shard|
          target = File.join(dir, "lib", shard.gsub('.', "_"))
          # The symlink lives inside lib/, one level deeper than the app root.
          link_target = File.join(rel, "..", shard)
          puts "      symlink lib/#{File.basename(target)} -> #{link_target}"
          File.symlink(link_target.to_s, target)
        end

        # Transitive shard deps installed inside the framework shards'
        # own lib/ dirs (active_record.cr needs db + pg at compile time).
        {"active_record.cr/lib/db", "active_record.cr/lib/pg"}.each do |dep|
          target = File.join(dir, "lib", File.basename(dep))
          next if File.exists?(target)
          link_target = File.join(rel, "..", dep)
          puts "      symlink lib/#{File.basename(dep)} -> #{link_target}"
          File.symlink(link_target.to_s, target)
        end

        write(dir, "shard.yml", shard_yml)
        write(dir, "src/app.cr", app_cr)
        write(dir, "src/console.cr", console_cr)
        write(dir, "config/application.cr", application_cr)
        write(dir, "config/initializers/content_security_policy.cr", content_security_policy_cr)
        write(dir, "config/routes.cr", routes_cr)
        write(dir, "config/importmap.cr", importmap_cr)
        write(dir, "config/database.yml", database_yml)
        write(dir, "config/environments/development.cr", development_cr)
        write(dir, "config/environments/production.cr", production_cr)
        write(dir, "app/controllers/application_controller.cr", application_controller_cr)
        write(dir, "app/controllers/welcome_controller.cr", welcome_controller_cr)
        write(dir, "app/models/application_record.cr", application_record_cr)
        write(dir, "app/views/layouts/application.html.erb", layout_erb)
        write(dir, "app/views/welcome/index.html.erb", index_erb)
        write(dir, "app/javascript/application.js", application_js)
        write(dir, "public/.gitkeep", "")
        write(dir, ".gitignore", gitignore)
        write(dir, "Procfile", procfile)
        write_master_key_and_credentials(dir)
        write(dir, "README.md", readme)
        write(dir, "bin/crails", bin_crails(exe))
        File.chmod(File.join(dir, "bin/crails"), 0o755)

        puts
        puts "CRails #{CRails::VERSION} app created at #{dir}"
        puts "Next steps:"
        puts "  cd #{@path}"
        puts "  bin/crails server"
        puts "  curl http://localhost:3000/"
      end

      private def write(dir : String, name : String, content : String) : Nil
        puts "      create  #{name}"
        File.write(File.join(dir, name), content)
      end

      # --- templates ---

      private def shard_yml : String
        <<-YAML
        # Framework shards come from lib/ symlinks (see bin/crails);
        # add your own dependencies here.
        name: #{@name}
        version: 0.1.0
        crystal: ">= 1.21.0"
        YAML
      end

      private def app_cr : String
        <<-CODE
        require "railties_cr"

        require "../config/application"
        require "../config/importmap"
        require "../app/controllers/**"
        require "../config/routes"
        require "../config/environments/development"
        require "../config/environments/production"

        CRails.application.initialize!
        CRails.application.boot(ARGV)
        CODE
      end

      private def importmap_cr : String
        <<-CODE
        # Pin your JavaScript modules (importmap-rails port, see
        # importmap.cr/PLAN.md). Paths resolve against app/javascript,
        # served at /javascripts/*.
        Importmap.map.draw do |map|
          map.pin "application"
        end
        CODE
      end

      private def application_js : String
        <<-JS
        // Entry point pinned in config/importmap.cr.
        // Add real modules next to this file and pin them there.
        JS
      end

      private def application_cr : String
        <<-CODE
        class Application < CRails::Application
          # config.port = 3000
          # config.host = "localhost"
        end

        CRails.application = Application.new
        CODE
      end

      # Procfile — роли процессов (crails supervise / foreman-совместимый).
      # worker/scheduler — хуки CRails.application.worker/scheduler;
      # роли, не скомпилированные в bin/app, supervise просто отключает.
      private def procfile : String
        <<-TEXT
        web: bin/app serve
        worker: bin/app worker
        scheduler: bin/app scheduler
        TEXT
      end

      # config/initializers/content_security_policy.cr — как rails new
      # (закомментированный DSL; раскомментируйте, чтобы включить CSP).
      private def content_security_policy_cr : String
        <<-CODE
        # Be sure to restart your server when you modify this file.
        #
        # Define an application-wide content security policy.
        # See the Securing Rails Applications Guide for more information:
        # https://guides.rubyonrails.org/security.html#content-security-policy-header

        # CRails.application.config.content_security_policy do |policy|
        #   policy.default_src :self, :https
        #   policy.font_src    :self, :https, :data
        #   policy.img_src     :self, :https, :data
        #   policy.object_src  :none
        #   policy.script_src  :self, :https
        #   policy.style_src   :self, :https
        #   # Specify URI for violation reports
        #   policy.report_uri "/csp-violation-report-endpoint"
        # end
        CODE
      end

      private def routes_cr : String
        <<-CODE
        CRails.application.routes.draw do
          root "welcome#index"
        end
        CODE
      end

      # Flat sections (no YAML anchors): establish_connection_from_yaml
      # reads adapter/host/port/username/password/database per env.
      # DATABASE_URL env var overrides this file when set (like Rails).
      private def database_yml : String
        <<-YAML
        # Picked up automatically by `crails console` (DATABASE_URL
        # overrides). host starting with "/" is a unix socket directory.
        development:
          adapter: postgresql
          host: /var/run/postgresql
          username: root
          database: #{@name}_development

        test:
          adapter: postgresql
          host: /var/run/postgresql
          username: root
          database: #{@name}_test

        production:
          adapter: postgresql
          host: /var/run/postgresql
          username: root
          database: #{@name}_production
          # for TCP + password deployments set host: db.example.com,
          # port: 5432, password: ... — or just use DATABASE_URL
        YAML
      end

      private def development_cr : String
        <<-CODE
        # Loaded when CRails.env == "development"
        if CRails.env.development?
          CRails.application.config.port = 3000
          # Allow requests to additional hosts (.localhost/.test and any
          # IP are allowed in development by default).
          # CRails.application.config.hosts += ["myapp.example.com"]
        end
        CODE
      end

      private def production_cr : String
        <<-CODE
        # Loaded when CRails.env == "production"
        if CRails.env.production?
          CRails.application.config.host = "0.0.0.0"
          # Force all access to the app over SSL, use Strict-Transport-
          # Security, and use secure cookies (ActionDispatch::SSL port).
          # CRails.application.config.force_ssl = true
          # Whitelist request hosts (ActionDispatch::HostAuthorization
          # port; empty = allow all).
          # CRails.application.config.hosts = ["example.com"]
        end
        CODE
      end

      private def application_controller_cr : String
        <<-CODE
        abstract class ApplicationController < ActionController::Base
          # CSRF-защита по умолчанию, как в Rails: POST/PUT/PATCH/DELETE
          # без валидного authenticity_token -> 422. Отключить точечно:
          #   skip_forgery_protection (или except: в protect_from_forgery)
          protect_from_forgery with: :exception
        end
        CODE
      end

      private def application_record_cr : String
        <<-CODE
        # Base class for models, like Rails' ApplicationRecord.
        # Attributes are generated from db/schema.yml at compile time
        # (`crails new` leaves it absent; dump one with ar_schema_dump).
        abstract class ApplicationRecord < ActiveRecord::Base
        end
        CODE
      end

      private def console_cr : String
        <<-CODE
        # CRails console bootstrap — loads the app WITHOUT starting the
        # server; used by `crails console` (every line re-runs this file).
        require "railties_cr"
        require "active_record_cr"
        require "../config/application"
        require "../app/models/**"
        require "../app/controllers/**"
        require "../config/routes"

        if (url = ENV["DATABASE_URL"]?)
          ActiveRecord::Base.establish_connection(url)
        elsif File.exists?("config/database.yml")
          ActiveRecord::Base.establish_connection_from_yaml(
            "config/database.yml", CRails.env.to_s.downcase)
        end
        CODE
      end

      private def welcome_controller_cr : String
        <<-'CODE'
        class WelcomeController < ApplicationController
          def index
          end
        end
        CODE
      end

      private def layout_erb : String
        <<-'ERB'
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>CRails</title>
            <%= csrf_meta_tags %>
            <%= javascript_importmap_tags %>
          </head>
          <body>
            <%= yield %>
          </body>
        </html>
        ERB
      end

      private def index_erb : String
        <<-'ERB'
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body {
            min-height: 100vh;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
              "Helvetica Neue", Arial, sans-serif;
            background: linear-gradient(160deg, #f4f8fb 0%, #eaf1f6 55%, #dde9f1 100%);
            color: #17263a;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 40px 16px;
          }
          .page { max-width: 720px; width: 100%; text-align: center; }
          .logo { margin-bottom: 24px; }
          h1 {
            font-size: clamp(2rem, 6vw, 3.5rem);
            letter-spacing: -0.03em;
            color: #1872b3;
          }
          .tagline {
            margin: 12px 0 36px;
            font-size: 1.1rem;
            color: #52677f;
          }
          .cards {
            display: flex;
            gap: 16px;
            justify-content: center;
            flex-wrap: wrap;
            margin-bottom: 36px;
          }
          .card {
            background: rgba(255, 255, 255, 0.75);
            backdrop-filter: blur(6px);
            border: 1px solid rgba(24, 114, 179, 0.18);
            border-radius: 14px;
            padding: 18px 28px;
            min-width: 170px;
            box-shadow: 0 4px 14px rgba(23, 38, 58, 0.06);
          }
          .card .label {
            display: block;
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: #7e97ae;
            margin-bottom: 6px;
          }
          .card .value { font-size: 1.2rem; font-weight: 600; color: #17263a; }
          .next {
            background: rgba(255, 255, 255, 0.75);
            border: 1px solid rgba(24, 114, 179, 0.18);
            border-radius: 14px;
            padding: 24px 28px;
            text-align: left;
            box-shadow: 0 4px 14px rgba(23, 38, 58, 0.06);
          }
          .next h2 { font-size: 1rem; color: #1872b3; margin-bottom: 14px; }
          .next ul { list-style: none; }
          .next li { padding: 6px 0; color: #52677f; font-size: 0.95rem; }
          .next code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            background: #17263a;
            color: #d7e6f2;
            border-radius: 6px;
            padding: 2px 8px;
            font-size: 0.85rem;
          }
          .rails { margin-top: 28px; color: #7e97ae; font-size: 0.9rem; }
          .rails span { color: #1872b3; font-weight: 600; }
        </style>
        <div class="page">
          <div class="logo">
            <svg width="96" height="96" viewBox="0 0 96 96" aria-hidden="true">
              <circle cx="48" cy="48" r="46" fill="#1872b3" opacity="0.08"/>
              <rect x="28" y="18" width="40" height="46" rx="12" fill="#1872b3"/>
              <rect x="34" y="26" width="13" height="12" rx="3" fill="#fff"/>
              <rect x="49" y="26" width="13" height="12" rx="3" fill="#fff"/>
              <rect x="34" y="44" width="28" height="8" rx="4" fill="#fff" opacity="0.9"/>
              <circle cx="38" cy="60" r="3" fill="#fff"/>
              <circle cx="58" cy="60" r="3" fill="#fff"/>
              <path d="M30 68 L22 82 M66 68 L74 82" stroke="#1872b3" stroke-width="4" stroke-linecap="round"/>
              <path d="M20 82 H76" stroke="#17263a" stroke-width="4" stroke-linecap="round"/>
            </svg>
          </div>
          <h1>Yay! You're on CRails!</h1>
          <p class="tagline">Rails, ported to Crystal — compiled, fast, familiar.</p>
          <div class="cards">
            <div class="card">
              <span class="label">CRails version</span>
              <span class="value"><%= CRails::VERSION %></span>
            </div>
            <div class="card">
              <span class="label">Crystal version</span>
              <span class="value"><%= Crystal::VERSION %></span>
            </div>
            <div class="card">
              <span class="label">Environment</span>
              <span class="value"><%= CRails.env.to_s.downcase %></span>
            </div>
          </div>
          <div class="next">
            <h2>What's next?</h2>
            <ul>
              <li><code>bin/crails server</code> — build and run the app on port 3000</li>
              <li><code>bin/crails console</code> — interactive console with your models loaded</li>
              <li><code>bin/crails routes</code> — list all routes</li>
              <li><code>bin/crails watch</code> — rebuild on change (dev loop)</li>
            </ul>
          </div>
          <p class="rails">Conventions over configuration — just like <span>Ruby on Rails</span>.</p>
        </div>
        ERB
      end

      private def gitignore : String
        <<-TEXT
        /lib/
        /bin/app
        /.shards/
        /config/master.key
        TEXT
      end

      # Rails 8 `rails new`: config/master.key (hex16, aes-128) +
      # зашифрованный credentials.yml.enc c secret_key_base (hex64).
      private def write_master_key_and_credentials(dir : String) : Nil
        key_path = File.join(dir, "config", "master.key")
        content_path = File.join(dir, "config", "credentials.yml.enc")
        key = Random::Secure.hex(16)
        FileUtils.mkdir_p(File.dirname(key_path))
        File.write(key_path, key)
        File.chmod(key_path, 0o600)
        template = <<-YAML
        # aws:
        #   access_key_id: 123
        #   secret_access_key: 345

        # used as the base secret for all MessageVerifiers in CRails, including the one protecting cookies
        secret_key_base: #{Random::Secure.hex(64)}
        YAML
        config = CRails::EncryptedConfiguration.new(
          content_path: content_path, key_path: key_path)
        config.write(template)
        puts "      create  config/master.key"
        puts "      create  config/credentials.yml.enc"
      end

      private def readme : String
        <<-MD
        # #{@name}

        Generated by `crails new` (Iteration 0: hello world, no DB).

        ```
        bin/crails server     # build + run on :3000
        bin/crails console    # rails console analog (loads app + DB, icr.cr)
        bin/crails routes     # list routes
        bin/crails watch      # rebuild on change (dev loop)
        ```

        Console queries (models in app/models, schema in db/schema.yml):
        the connection is picked up automatically from
        config/database.yml (DATABASE_URL overrides it if set).

        ```
        bin/crails c
        crails(dev)> Post.count
        crails(dev)> Post.where(published: true).order(:views).limit(3).to_a
        ```
        MD
      end

      private def bin_crails(exe : String) : String
        <<-SH
        #!/bin/sh
        # CRails dev CLI wrapper (generated; points at the crails binary).
        exec "#{exe}" "$@"
        SH
      end
    end
  end
end
