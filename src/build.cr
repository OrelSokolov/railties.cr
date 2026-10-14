module CRails
  module CLI
    module Build
      def self.ensure_app : Nil
        unless File.exists?("shard.yml") && File.exists?("src/app.cr")
          abort "ERROR: not in a CRails app (no shard.yml / src/app.cr). Run from the app root."
        end
        if File.read("shard.yml").includes?("dependencies:") && !Dir.exists?("lib")
          puts "==> shards install"
          system("shards", ["install"]) || abort("ERROR: shards install failed")
        end
      end

      # Builds bin/app. Returns true on success.
      def self.build(release : Bool = false) : Bool
        args = ["build", "src/app.cr", "-o", "bin/app"]
        args << "--release" if release
        puts "==> crystal build src/app.cr -o bin/app#{" --release" if release}"
        started = Time.instant
        ok = system("crystal", args)
        if ok
          elapsed = (Time.instant - started).total_seconds.round(2)
          puts "    compiled in #{elapsed}s"
        end
        ok
      end
    end
  end
end
