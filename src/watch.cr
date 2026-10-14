require "./build"

module CRails
  module CLI
    # `crails watch` — the dev loop replacement for Rails reloading:
    # poll sources, rebuild the binary and restart the server on change.
    module Watch
      WATCH_GLOBS = ["src/**/*.cr", "config/**/*.cr", "app/**/*.cr",
                     "app/**/*.erb", "shard.yml"]

      def self.run(args : Array(String)) : Nil
        Build.ensure_app

        app_args = ["serve"]
        i = 0
        while i < args.size
          case args[i]
          when "-p", "--port" then app_args << "-p" << args[i + 1]; i += 2
          when "-b", "--bind" then app_args << "-b" << args[i + 1]; i += 2
          else
            abort "ERROR: unknown option #{args[i]}"
          end
        end

        Build.build || puts "!! initial build failed; waiting for changes"

        child = start_server(app_args)
        Signal::INT.trap { stop(child); exit }

        loop do
          sleep 0.4.seconds
          next unless changed?
          puts "==> change detected; rebuilding"
          stop(child)
          child = start_server(app_args) if Build.build
        end
      end

      private def self.start_server(app_args : Array(String)) : Process
        puts "==> bin/app #{app_args.join(" ")}"
        Process.new("bin/app", app_args, output: STDOUT, error: STDERR)
      end

      private def self.stop(child : Process) : Nil
        child.terminate
        child.wait
      rescue ex
        # already dead — fine
      end

      @@snapshot : Hash(String, Time)?

      private def self.changed? : Bool
        files = WATCH_GLOBS.flat_map { |g| Dir.glob(g) }
        current = {} of String => Time
        files.each { |f| current[f] = File.info(f).modification_time }
        previous = @@snapshot
        @@snapshot = current
        !previous || previous != current
      end
    end
  end
end
