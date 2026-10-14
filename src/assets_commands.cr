# Выполнение `assets:TASK` поверх готовой Propshaft::Assembly.
# Вызывается из двух мест:
# - Application#boot (`bin/app assets:*`) — окружение приложения:
#   кастомный config.assets.paths виден (паритет с rake-тасками
#   propshaft, грузящими environment);
# - CLI `crails assets:*` в bare-FS режиме (нет исходников
#   приложения, напр. Docker-стадия) — load path только из ФС.

module CRails
  module AssetsCommands
    def self.execute(assembly : Propshaft::Assembly, task : String,
                     argv : Array(String) = [] of String) : Nil
      merge_env_paths(assembly)
      case task
      when "precompile" then precompile(assembly)
      when "clean"
        count = count_arg(argv)
        assembly.processor.clean(count, 1.hour)
        puts "cleaned #{assembly.config.output_path} (kept #{count} version(s) per asset)"
      when "clobber"
        assembly.processor.clobber
        puts "removed #{assembly.config.output_path}"
      when "reveal"
        assembly.load_path.assets.each { |asset| puts asset.logical_path }
      when "help", "-h"
        help
      else
        STDERR.puts "Unknown assets task: #{task}"
        help
        exit 1
      end
    end

    # Дополнительные load path через CRAILS_ASSETS_PATHS
    # (colon-separated) — работают в обоих режимах. Должно быть
    # вызвано до первого обращения к assembly.load_path (пути
    # снапшотятся при его создании).
    private def self.merge_env_paths(assembly : Propshaft::Assembly) : Nil
      extra = (ENV["CRAILS_ASSETS_PATHS"]? || "")
        .split(':').map(&.strip).reject(&.empty?)
      return if extra.empty?
      assembly.config.paths = (assembly.config.paths + extra).uniq
    end

    private def self.precompile(assembly : Propshaft::Assembly) : Nil
      assets = assembly.load_path.assets
      if assets.empty?
        STDERR.puts "No assets found in #{assembly.config.paths.join(", ")}"
        return
      end
      output = assembly.config.output_path
      skipped = assets.count { |a| File.exists?(File.join(output, a.digested_path)) }
      manifest = assembly.processor.process
      puts "#{assets.size} assets, #{assets.size - skipped} written, " \
           "#{skipped} skipped (#{manifest.to_json.bytesize}B manifest)"
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
        Usage: bin/app assets:TASK   (from an app root: crails assets:TASK)

        Tasks:
          precompile   Compile all assets from the load path into the output path
                       (digest names, .manifest.json, .gz/.br precompression)
          clean        Remove old versions in the output path (keep COUNT, default 2)
          clobber      Remove the output path entirely
          reveal       Print all logical asset paths in the load path
        TEXT
    end
  end
end
