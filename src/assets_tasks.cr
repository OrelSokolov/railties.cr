# `crails assets:*` — precompile / clean / clobber / reveal
# (порты rake-тасок propshaft 1.3.2, railties/assets.rake).
#
# В отличие от db:* (генерирующих runner под app-код), процессинг
# ассетов не требует кода приложения: load path — файловая система
# (app/assets/* + vendor), так что бинарник crails выполняет Processor
# напрямую. Дополнительные пути — через CRAILS_ASSETS_PATHS (colon-
# separated); кастомный config.assets.paths приложения CLI не видит
# (задокументированное отклонение, см. propshaft_cr/PLAN.md).

module CRails
  module CLI
    module Assets
      def self.run(argv : Array(String)) : Nil
        task = argv[0]? || "help"
        task = task.split(':', 2)[1]? || "help" if task.starts_with?("assets:")
        rest = task == argv[0]? ? argv[1..] : argv
        case task
        when "precompile" then precompile
        when "clean"      then clean(count_arg(rest))
        when "clobber"    then clobber
        when "reveal"     then reveal
        when "help", "-h" then help
        else
          STDERR.puts "Unknown assets task: #{task}"
          help
          exit 1
        end
      end

      private def self.build_assembly : Propshaft::Assembly
        config = CRails::Config.new.assets
        paths = default_paths
        extra = (ENV["CRAILS_ASSETS_PATHS"]? || "")
          .split(':').map(&.strip).reject(&.empty?)
        config.paths = (paths + extra).uniq
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

      private def self.precompile : Nil
        assembly = build_assembly
        assets = assembly.load_path.assets
        if assets.empty?
          STDERR.puts "No assets found in #{assembly.config.paths.join(", ")}"
          return
        end
        skipped = assets.count { |a| File.exists?(File.join("public/assets", a.digested_path)) }
        manifest = assembly.processor.process
        written = assets.size - skipped
        puts "#{assets.size} assets, #{written} written, #{skipped} skipped " \
             "(#{manifest.to_json.bytesize}B manifest)"
      end

      private def self.clean(count : Int32) : Nil
        build_assembly.processor.clean(count, 1.hour)
        puts "cleaned public/assets (kept #{count} version(s) per asset)"
      end

      private def self.clobber : Nil
        build_assembly.processor.clobber
        puts "removed public/assets"
      end

      private def self.reveal : Nil
        build_assembly.load_path.assets.each { |a| puts a.logical_path }
      end

      private def self.count_arg(argv : Array(String)) : Int32
        argv.each_with_index do |a, i|
          if a == "COUNT"
            return argv[i + 1]?.try(&.to_i) || 2
          elsif a.starts_with?("COUNT=")
            return a.split('=', 2)[1].to_i
          end
        end
        2
      end

      private def self.help : Nil
        puts <<-TEXT
          Usage: crails assets:TASK

          Tasks:
            precompile   Compile all assets from app/assets/* + vendor into public/assets
                         (digest names, .manifest.json, .gz/.br precompression)
            clean        Remove old versions in public/assets (keep COUNT, default 2)
            clobber      Remove public/assets entirely
            reveal       Print all logical asset paths in the load path
        TEXT
      end
    end
  end
end
