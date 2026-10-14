# CRails::CLI::Deploy — `crails deploy user@host[:dir]` (Iteration 11).
#
# P0 deploy pipeline (a compiled binary makes this trivial vs Ruby):
#   1. release build locally (bin/app)
#   2. scp bin/app to HOST:DIR/bin/app.new
#   3. run migrations on the host: bin/app db:migrate
#   4. zero-downtime restart: start the new binary next to the old one
#      (CRAILS_REUSE_PORT=1), then TERM the old process (graceful drain)
#
# Requires ssh key auth + the host to have the same libc/architecture.

module CRails
  module CLI
    module Deploy
      def self.run(args : Array(String)) : Nil
        target = args[0]? || abort(usage)
        host, dir = parse_target(target)
        Build.ensure_app
        Build.build(release: true) || abort("ERROR: release build failed")

        puts "==> deploy to #{host}:#{dir}"
        sh("ssh", [host, "mkdir -p #{dir}/bin #{dir}/log #{dir}/tmp/pids"])
        sh("scp", ["bin/app", "#{host}:#{dir}/bin/app.new"])
        sh("ssh", [host, "cd #{dir} && mv bin/app.new bin/app && chmod +x bin/app"])

        # Migrate with the new binary before switching traffic to it.
        sh("ssh", [host, "cd #{dir} && CRAILS_ENV=production bin/app db:migrate"])

        # Zero-downtime restart: new process binds alongside (reuse_port),
        # old one gets TERM and drains in-flight requests.
        sh("ssh", [host, restart_command(dir)])
        puts "==> deployed: #{host}:#{dir} (CRAILS_ENV=production, port #{port})"
        puts "    health check: curl http://#{host.split('@').last}/up"
      end

      private def self.usage : Nil
        abort "Usage: crails deploy user@host[:dir]   (default dir: ~/app)"
      end

      private def self.parse_target(target : String) : {String, String}
        if idx = target.rindex(':')
          {target[0...idx], target[(idx + 1)..]}
        else
          {target, "~/app"}
        end
      end

      private def self.port : String
        ENV["PORT"]? || "3000"
      end

      private def self.restart_command(dir : String) : String
        <<-CMD
        cd #{dir} && \
        (cat tmp/pids/app.pid 2>/dev/null | xargs -r kill -TERM || true) && \
        CRAILS_ENV=production CRAILS_REUSE_PORT=1 PORT=#{port} \
          nohup bin/app serve -p #{port} >> log/production.log 2>&1 & \
        sleep 1 && echo "restarted pid $(cat tmp/pids/app.pid)"
        CMD
      end

      private def self.sh(cmd : String, args : Array(String) | String) : Nil
        puts "==> #{cmd} #{args.is_a?(String) ? args : args.join(' ')}"
        system(cmd, args) || abort("ERROR: #{cmd} failed")
      end
    end
  end
end
