require "./build"

module CRails
  module CLI
    module Server
      def self.run(args : Array(String)) : Nil
        Build.ensure_app

        port : String? = nil
        host : String? = nil
        env = "development"
        i = 0
        while i < args.size
          case args[i]
          when "-p", "--port" then port = args[i + 1]; i += 2
          when "-b", "--bind" then host = args[i + 1]; i += 2
          when "-e", "--env"  then env = args[i + 1]; i += 2
          else
            abort "ERROR: unknown option #{args[i]}"
          end
        end

        ENV["CRAILS_ENV"] = env
        release = env == "production"
        Build.build(release) || abort("ERROR: build failed")

        app_args = ["serve"]
        app_args << "-p" << port if port
        app_args << "-b" << host if host
        Process.exec("bin/app", app_args)
      end
    end
  end
end
