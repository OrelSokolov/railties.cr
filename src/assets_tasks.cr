# `crails assets:*` — precompile / clean / clobber / reveal
# (порты rake-тасок propshaft 1.3.2, railties/assets.rake).
#
# В приложении (src/app.cr + config/application.cr) таска выполняется
# в окружении приложения — как `crails routes`: собираем bin/app и
# передаём команду; кастомный config.assets.paths приложения виден
# (Application#cmd_assets → CRails::AssetsCommands).
#
# Bare-FS режим (исходников приложения нет, напр. Docker-стадия):
# бинарник crails выполняет AssetsCommands напрямую; load path —
# только файловая система (app/assets/* + vendor) + env
# CRAILS_ASSETS_PATHS (colon-separated).

module CRails
  module CLI
    module Assets
      def self.run(argv : Array(String)) : Nil
        task = argv[0]? || "help"
        task = task.split(':', 2)[1]? || "help" if task.starts_with?("assets:")
        rest = task == argv[0]? ? argv[1..] : argv

        return CRails::AssetsCommands.execute(build_assembly, "help") \
          if {"help", "-h"}.includes?(task)

        if File.exists?("src/app.cr") && File.exists?("config/application.cr")
          Build.ensure_app
          Build.build || exit 1
          Process.exec("bin/app", ["assets:#{task}"] + rest)
        end

        CRails::AssetsCommands.execute(build_assembly, task, rest)
      end

      # Bare-FS assembly: load path из ФС (приложение недоступно —
      # его config.assets.paths здесь не учитывается).
      private def self.build_assembly : Propshaft::Assembly
        config = CRails::Config.new.assets
        config.paths = default_paths
        config.output_path = "public/assets"
        config.manifest_path = "public/assets/.manifest.json"
        config.versions = [".gz", ".br"]
        Propshaft::Assembly.new(config)
      end

      # Дефолтные load path — как Propshaft::Railtie: подкаталоги
      # app/assets/* + vendor/assets/* + vendor/javascript (пины).
      private def self.default_paths : Array(String)
        (Dir.glob("app/assets/*") + Dir.glob("vendor/assets/*") + ["vendor/javascript"])
          .select { |d| Dir.exists?(d) }
      end
    end
  end
end
