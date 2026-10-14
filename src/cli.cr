require "./generator"
require "./generators/base"
require "./generators/fields"
require "./generators/migration_builder"
require "./generators/model_files"
require "./generators/app_glue"
require "./generators/migration_generator"
require "./generators/model_generator"
require "./generators/helper_generator"
require "./generators/job_generator"
require "./generators/mailer_generator"
require "./generators/channel_generator"
require "./generators/mailbox_generator"
require "./generators/controller_generator"
require "./generators/scaffold_generator"

module CRails
  module CLI
    GENERATORS = {
      "channel"    => Generators::ChannelGenerator,
      "controller" => Generators::ControllerGenerator,
      "helper"     => Generators::HelperGenerator,
      "job"        => Generators::JobGenerator,
      "mailbox"    => Generators::MailboxGenerator,
      "mailer"     => Generators::MailerGenerator,
      "migration"  => Generators::MigrationGenerator,
      "model"      => Generators::ModelGenerator,
      "scaffold"   => Generators::ScaffoldGenerator,
    }

    GENERATOR_HELP = {
      "channel"    => "Generate a new Action Cable channel (app/channels/)",
      "controller" => "Generate a controller with views and a routes entry",
      "helper"     => "Generate a helper module (app/helpers/)",
      "job"        => "Generate an Active Job class (app/jobs/)",
      "mailbox"    => "Generate an Action Mailbox class (app/mailboxes/)",
      "mailer"     => "Generate a mailer with views (app/mailers/)",
      "migration"  => "Generate a migration (db/migrate/)",
      "model"      => "Generate a model with a migration, spec and fixture",
      "scaffold"   => "Scaffold a full resource (model + RESTful controller + views + routes)",
    }

    def self.run(argv : Array(String)) : Nil
      case argv[0]? || "help"
      when "new"       then Generators::App.run(argv[1]? || abort("Usage: crails new APP_PATH"))
      when "server", "s" then Server.run(argv[1..])
      when "console", "c" then Console.run(argv[1..])
      when "routes"    then Build.ensure_app; Build.build; run_app(["routes"])
      when "credentials:show", "credentials:edit" then
        Build.ensure_app; Build.build; run_app(credentials_args(argv))
      when "secret"    then puts Random::Secure.hex(64)
      when "middleware" then Build.ensure_app; Build.build; run_app(["middleware"])
      when "watch"     then Watch.run(argv[1..])
      when "supervise" then Build.ensure_app; Build.build; Supervisor.run(argv[1..])
      when "db", .starts_with?("db:") then DB.run(argv)
      when "assets", .starts_with?("assets:") then Assets.run(argv)
      when "deploy"    then Deploy.run(argv[1..])
      when "generate", "g" then generate_cmd(argv[1..], :invoke)
      when "destroy", "d"  then generate_cmd(argv[1..], :revoke)
      when "bot:poll" then Agent.poll(argv[1..])
      when "version", "--version", "-v" then puts "CRails #{CRails::VERSION} (Crystal #{Crystal::VERSION})"
      when "about"     then about
      else help
      end
    end

    private def self.generate_cmd(argv : Array(String), behavior : Symbol) : Nil
      verb = behavior == :invoke ? "generate" : "destroy"
      case argv[0]?
      when nil, "--help", "-h" then return list_generators(verb)
      when "bot"
        return abort "Usage: crails generate bot NAME [--platform=telegram|whatsapp]" if behavior == :revoke
        return Agent.generate(argv[1..])
      end

      klass = GENERATORS[argv[0]]?
      return abort "Could not find generator #{argv[0]}. Run `crails generate` for a list." unless klass
      if argv[1..].any? { |a| {"--help", "-h"}.includes?(a) }
        gen = klass.new
        puts gen.usage
        puts
        puts "  #{GENERATOR_HELP[argv[0]]}"
        puts
        puts "Options:"
        puts "  [--force] [-f]   Overwrite existing files"
        puts "  [--skip] [-s]    Skip existing files"
        puts "  [--pretend] [-p] Run but do not write anything"
        puts "  [--quiet] [-q]   Suppress status output"
        return
      end
      klass.run(argv[1..], behavior)
    end

    private def self.list_generators(verb : String = "generate") : Nil
      puts "Usage: crails #{verb} GENERATOR [args] [options]"
      puts
      puts "Please select a generator:"
      puts "  bot"
      GENERATORS.each_key { |name| puts "  #{name}" }
    end

    private def self.about : Nil
      puts <<-TEXT
      CRails     #{CRails::VERSION}
      Crystal    #{Crystal::VERSION}
      Env        #{CRails.env}
      Root       #{CRails.root}
      Iteration  0 (hello world; no DB, no sessions yet)
      TEXT
    end

    private def self.help : Nil
      puts <<-TEXT
      CRails #{CRails::VERSION} — a Rails-port MVC framework on Crystal (EXPERIMENTAL)

      Usage: crails COMMAND [ARGS]

      Commands:
        new APP_PATH   Generate a new application
        server, s      Build and run the app (-p PORT, -b HOST, -e ENV)
        console, c     Rails-console analog on icr.cr (loads app + DB)
        routes         Build (if needed) and list routes
        middleware     List the middleware stack (rake middleware analog)
        watch          Rebuild + restart on source changes (dev loop)
        supervise      Run all Procfile roles under a supervisor
                       (web/worker/scheduler; restarts on crash, Ctrl-C stops all)
        db:migrate     Run pending migrations (db/migrate/*.cr)
        db:rollback    Roll back the last migration (STEP=n)
        db:schema:dump Refresh db/schema.cr + db/schema.yml
        db:schema:load Recreate the database from db/schema.cr
        assets:precompile  Compile assets into public/assets (digest names,
                           .manifest.json, .gz/.br); assets:clean|clobber|reveal
                           too. In an app: runs in the app environment
                           (custom config.assets.paths visible)
        generate, g  Generate code: model controller scaffold migration mailer
                     job channel mailbox helper bot (`crails g` lists them)
        destroy, d   Undo a generator (`crails destroy model Post`)
        bot:poll     Build the app and run its bot poller role
                       (crails bot:poll telegram)
        deploy         Release-build + scp + migrate + zero-downtime restart
        version        Print versions
        about          Print framework info
      TEXT
    end

    private def self.run_app(args : Array(String)) : Nil
      Process.exec("bin/app", args)
    end

    # Проброс --environment/-e ENV в bin/app (гем: EnvironmentArgument;
    # прочие опции CLI-оболочка не пропускает).
    private def self.credentials_args(argv : Array(String)) : Array(String)
      args = [argv[0]]
      rest = argv[1..]
      i = 0
      while i < rest.size
        case rest[i]
        when "--environment", "-e"
          args.concat(["--environment", rest[i + 1]]) if rest[i + 1]?
          i += 2
        when .starts_with?("--environment=")
          args << rest[i]
          i += 1
        else
          i += 1
        end
      end
      args
    end
  end
end

require "./build"
require "./server"
require "./watch"
require "./supervisor"
require "./console_cmd"
require "./db_tasks"
require "./assets_tasks"
require "./deploy"
require "./agent_tasks"
