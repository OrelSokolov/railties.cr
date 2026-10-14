require "file_utils"

module CRails
  module Agent
    # `crails generate bot NAME [--platform=telegram|whatsapp]` — embeds
    # an ActionBot bot into the application (Iteration 16): the bot is
    # a first-class app citizen living in app/bots/, compiled into the
    # same binary, with direct access to models/jobs/cache (CRM-ready).
    def self.generate(argv : Array(String)) : Nil
      name = argv[0]? || abort("Usage: crails generate bot NAME [--platform=telegram]")
      platform = "telegram"
      argv.each_with_index do |a, i|
        if a.starts_with?("--platform")
          platform = a.includes?('=') ? a.split('=', 2)[1] : (argv[i + 1]? || "telegram")
        end
      end
      abort "ERROR: platform must be telegram or whatsapp (got #{platform})" \
        unless {"telegram", "whatsapp"}.includes?(platform)

      klass = name.split(/[_-]/).map(&.capitalize).join
      klass = klass + "Bot" unless klass.ends_with?("Bot")
      file_name = klass.underscore + ".cr"

      exe = Process.executable_path || abort("ERROR: cannot locate the crails binary")
      railties_dir = File.dirname(File.dirname(exe)) # railties.cr/
      repo_root = File.dirname(railties_dir)          # monorepo root

      dir = Dir.current
      abort "ERROR: app/bots belongs in a CRails app (config/application.cr not found here)" \
        unless File.exists?(File.join(dir, "config/application.cr"))

      # lib/action_bot_cr symlink (dev mode, like the App generator).
      symlink = File.join(dir, "lib", "action_bot_cr")
      unless File.exists?(symlink)
        target = File.join(repo_root, "action_bot.cr")
        abort "ERROR: #{target} not found (monorepo layout expected)" unless File.exists?(target)
        FileUtils.mkdir_p(File.join(dir, "lib"))
        puts "      symlink lib/action_bot_cr"
        File.symlink(target, symlink)
      end

      FileUtils.mkdir_p(File.join(dir, "app", "bots"))
      bot_file = File.join(dir, "app", "bots", file_name)
      abort "ERROR: #{bot_file} already exists" if File.exists?(bot_file)
      puts "      create  app/bots/#{file_name}"
      File.write(bot_file, bot_template(klass, platform))

      # config/bots.yml — tokens stay in ENV (bots.yml documents them).
      agents_yml = File.join(dir, "config", "bots.yml")
      unless File.exists?(agents_yml)
        puts "      create  config/bots.yml"
        File.write(agents_yml, agents_yml_template)
      end

      # src/app.cr: require the bots directory.
      app_cr = File.join(dir, "src", "app.cr")
      patch(app_cr) do |src|
        next src if src.includes?("app/bots/**")
        src.gsub(/require "\.\.\/app\/controllers\/\*\*"/) do |m|
          "#{m}\nrequire \"../app/bots/**\""
        end || src
      end

      # config/application.cr: mount /bot/webhooks + /bot/sse.
      app_config = File.join(dir, "config", "application.cr")
      patch(app_config) do |src|
        next src if src.includes?("/bot/webhooks")
        if src.includes?("def call(context : HTTP::Server::Context)")
          # existing custom call (e.g. a /cable mount): early-return
          # guards — paths are prefixes, not exact case matches.
          src.gsub("case context.request.path") do |m|
            "return ActionBot.webhook_handler.call(context) if context.request.path.starts_with?(\"/bot/webhooks\")\n" \
            "    return ActionBot.sse_handler.call(context) if context.request.path.starts_with?(\"/bot/sse\")\n" \
            "    #{m}"
          end || src
        else
          # default generated app: inject a call override before `end`.
          mount = <<-CODE

              # ActionBot mounts (crails generate bot): all bots are
              # served under /bot/webhooks/:platform/:bot; SSE at /bot/sse/:bot.
              def call(context : HTTP::Server::Context) : Nil
                if context.request.path.starts_with?("/bot/webhooks")
                  ActionBot.webhook_handler.call(context)
                elsif context.request.path.starts_with?("/bot/sse")
                  ActionBot.sse_handler.call(context)
                else
                  super
                end
              end
            CODE
          idx = src.rindex("end") || abort("ERROR: cannot patch #{app_config}")
          src.insert(idx, mount + "\n")
        end
      end

      puts
      puts "Bot #{klass} (#{platform}) embedded:"
      puts "  app/bots/#{file_name}   — handlers; edit freely (models/jobs reachable)"
      puts "  webhook URL: /bot/webhooks/#{platform}/#{klass.underscore[..-5]}"
      puts "  config/bots.yml   — token env vars documented"
      puts "  Set #{platform == "telegram" ? "TELEGRAM_BOT_TOKEN (+TELEGRAM_SECRET_TOKEN for webhook auth)" : "WHATSAPP_ACCESS_TOKEN + WHATSAPP_PHONE_NUMBER_ID + WHATSAPP_APP_SECRET"} and run:"
      puts "    bin/crails bot:poll #{platform}   # polling transport (no webhook needed)"
    end

    # `crails bot:poll [platform]` — build the app and run its poller
    # role (bots are compiled into bin/app).
    def self.poll(argv : Array(String)) : Nil
      CLI::Build.ensure_app
      CLI::Build.build
      Process.exec("bin/app", ["bot:poll"] + argv)
    end

    private def self.patch(path : String, &) : Nil
      return unless File.exists?(path)
      src = File.read(path)
      patched = yield src
      return if patched == src
      puts "      patch   #{path}"
      File.write(path, patched)
    end

    private def self.bot_template(klass : String, platform : String) : String
      <<-CODE
      require "action_bot_cr"

      # #{klass} — embedded in this app: handlers run in the app process
      # and can call models/jobs/cache directly (CRM glue lives here).
      class #{klass} < ActionBot::Base
        adapter "#{platform}"

        command "start" do |m|
          reply.text "Привет! Я бот приложения (#{platform})."
        end

        message do |m|
          reply.text "Вы сказали: \#{m.text}"
        end

        callback_query do |q|
          reply.text "Выбрано: \#{q.data}"
        end
      end

      # Wire `bin/app bot:poll #{platform}` (CRails boot glue; railties
      # itself stays free of an action_bot dependency).
      CRails.application.bot_poller = ->(platform : String) do
        ActionBot::Poller.for(platform).run
      end
      CODE
    end

    private def self.agents_yml_template : String
      <<-YAML
      # ActionBot adapters (tokens via ENV — never commit secrets).
      #
      # telegram:
      #   TELEGRAM_BOT_TOKEN:      bot token from @BotFather
      #   TELEGRAM_SECRET_TOKEN:   X-Telegram-Bot-Api-Secret-Token (webhook auth)
      # whatsapp:
      #   WHATSAPP_ACCESS_TOKEN:   permanent token (graph.facebook.com)
      #   WHATSAPP_PHONE_NUMBER_ID: phone number id
      #   WHATSAPP_APP_SECRET:     X-Hub-Signature-256 HMAC key
      #   WHATSAPP_VERIFY_TOKEN:   webhook verification echo token
      YAML
    end
  end
end
