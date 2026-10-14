# Generators core — a mini port of Rails::Generators (thor layer):
# invoke/revoke behaviors, `invoke`/`create`/`identical`/`remove`/`route`
# log lines, common options (--force/--skip/--pretend/--quiet/--no-X).
#
# Oracle: oracle/generators_expected.yml (Rails 8.1.4). The log format is
# byte-exact: status right-justified in 12 columns, then 2*(depth+1) spaces.

module CRails
  module Generators
    class CollisionError < Exception
    end

    class Base
      # :invoke (generate) or :revoke (destroy).
      property behavior : Symbol = :invoke
      property? force : Bool = false
      property? skip : Bool = false
      property? pretend : Bool = false
      property? quiet : Bool = false
      property skip_collision_check : Bool = false

      @depth = 0

      def self.generator_name : String
        {{ @type.name.split("::").last.underscore.gsub(/_generator$/, "") }}
      end

      def self.run(argv : Array(String), behavior : Symbol = :invoke) : Nil
        opts, args = parse_options(argv)
        gen = new
        gen.behavior = behavior
        gen.force = opts.delete("force") || false
        gen.skip = opts.delete("skip") || false
        gen.pretend = opts.delete("pretend") || false
        gen.quiet = opts.delete("quiet") || false
        gen.skip_collision_check = opts.delete("skip-collision-check") || false
        gen.options = opts
        gen.args = args
        gen.generate
      end

      # --name / --no-name / --skip-name / -f / -s / -p / -q are options,
      # everything else is positional.
      def self.parse_options(argv : Array(String)) : {Hash(String, Bool), Array(String)}
        opts = Hash(String, Bool).new
        args = [] of String
        argv.each do |a|
          case a
          when "-f", "--force"                then opts["force"] = true
          when "-s", "--skip"                 then opts["skip"] = true
          when "-p", "--pretend", "--dry-run" then opts["pretend"] = true
          when "-q", "--quiet"                then opts["quiet"] = true
          when "--skip-collision-check"       then opts["skip-collision-check"] = true
          when .starts_with?("--no-")
            opts[a[5..]] = false
          when .starts_with?("--skip-")
            opts[a[7..]] = false
          when .starts_with?("--")
            opts[a[2..]] = true
          else
            args << a
          end
        end
        {opts, args}
      end

      property options : Hash(String, Bool) = Hash(String, Bool).new
      property args : Array(String) = [] of String
      # Status output (injectable for specs).
      property output : IO = STDOUT

      def option?(name : String, default = true) : Bool
        return options[name] if options.has_key?(name)
        default
      end

      def generate : Nil
        raise NotImplementedError.new("#{self.class} must define #generate")
      end

      # --- log ---------------------------------------------------------------

      def say(status : String, message : String, depth : Int32 = @depth) : Nil
        return if quiet?
        @output.puts status.rjust(12) + ("  " * (depth + 1)) + message
      end

      # `invoke :active_record do ... end` — prints the invoke line and runs
      # the block one nesting level deeper (revocation keeps the lines).
      def invoke(name : String, &) : Nil
        say("invoke", name)
        @depth += 1
        begin
          yield
        ensure
          @depth -= 1
        end
      end

      # invoke without a block — just the invoke line (Rails prints
      # `invoke resource_route` for already-satisfied hooks).
      def invoke(name : String) : Nil
        say("invoke", name)
      end

      # --- actions -------------------------------------------------------------

      def create_file(path : String, content : String) : Nil
        if behavior == :revoke
          if File.exists?(path)
            File.delete(path) unless pretend?
            say("remove", path)
          end
          return
        end

        if File.exists?(path)
          if File.read(path) == content
            say("identical", path)
            return
          end
          if force?
            File.write(path, content) unless pretend?
            say("force", path)
          elsif skip?
            say("skip", path)
          else
            raise CollisionError.new(path)
          end
          return
        end

        FileUtils.mkdir_p(File.dirname(path)) unless pretend?
        File.write(path, content) unless pretend?
        say("create", path)
      end

      def create_dir(path : String) : Nil
        if behavior == :revoke
          if File.exists?(path)
            unless pretend?
              begin
                Dir.delete(path)
              rescue File::Error
              end
            end
            say("remove", path)
          end
          return
        end
        return say("create", path) if pretend?
        return if Dir.exists?(path)
        FileUtils.mkdir_p(path)
        say("create", path)
      end

      # Insert/remove routing lines in config/routes.cr. Creates the file
      # (with the standard draw skeleton) when missing.
      def route(lines : Array(String)) : Nil
        path = "config/routes.cr"
        if behavior == :revoke
          return unless File.exists?(path)
          src = File.read(path)
          changed = src
          lines.each { |l| changed = changed.gsub("\n  #{l}\n", "\n") }
          changed = changed.gsub("#{lines[0]}\n", "") # first line right after `draw do`
          return if changed == src
          File.write(path, changed) unless pretend?
          say_route(lines)
          return
        end

        FileUtils.mkdir_p("config") unless pretend?
        unless File.exists?(path)
          content = "CRails.application.routes.draw do\nend\n"
          File.write(path, content) unless pretend?
        end
        src = File.read(path) unless pretend?
        src ||= "CRails.application.routes.draw do\nend\n"
        anchor = "CRails.application.routes.draw do\n"
        idx = src.index(anchor) || 0
        inserted = src.insert(idx + anchor.size, lines.map { |l| "  #{l}\n" }.join)
        File.write(path, inserted) unless pretend?
        say_route(lines)
      end

      private def say_route(lines : Array(String)) : Nil
        return if quiet?
        indent = " " * (12 + 2 * (@depth + 1))
        lines.each_with_index do |l, i|
          @output.print i == 0 ? "       route".ljust(12 + 2 * (@depth + 1)) : indent
          @output.puts l
        end
      end

      # Append a line to a file (thor `append_to_file`).
      def append_file(path : String, line : String) : Nil
        if behavior == :revoke
          return unless File.exists?(path)
          src = File.read(path)
          changed = src.gsub("\n#{line}\n", "\n").gsub(/^#{line}\n/, "")
          return if changed == src
          File.write(path, changed) unless pretend?
          say("gsub", path)
          return
        end
        return unless File.exists?(path)
        src = File.read(path)
        return if src.includes?(line)
        File.write(path, src.chomp + "\n" + line + "\n") unless pretend?
        say("append", path)
      end

      # Rails' class collision check: warn on stderr and stop the generator
      # (the CLI exits 0 afterwards, like Rails) when the main class file
      # already exists. Returns true when the generator must stop.
      def check_class_collision(file : String, class_name : String) : Bool
        return false if skip_collision_check || force? || skip? || behavior == :revoke
        return false unless File.exists?(file)
        STDERR.puts "The name '#{class_name}' is either already used in your " \
                    "application or reserved by CRails. Please choose an " \
                    "alternative or use --skip-collision-check or --force to " \
                    "skip this check and run this generator again."
        true
      end

      # Migration file name for `suffix` (e.g. "create_posts"): keeps the
      # current timestamp when the exact file already exists (a re-run with
      # --force stays `identical`), otherwise bumps past the latest existing
      # migration so same-second runs never share a version and run order
      # always matches generation order (CRails deviation: the migrator
      # orders strictly by version).
      def self.migration_filename(suffix : String) : String
        dir = File.join("db", "migrate")
        now = Time.utc.to_s("%Y%m%d%H%M%S")
        return "#{now}_#{suffix}.cr" if File.exists?(File.join(dir, "#{now}_#{suffix}.cr"))

        ts = now.to_i64
        Dir.glob(File.join(dir, "*.cr")).each do |path|
          next unless digits = File.basename(path).match(/^\d+/)
          next unless n = digits[0].to_i64?
          ts = n + 1 if n >= ts
        end
        "#{ts}_#{suffix}.cr"
      end
    end

    # Named generators take NAME [actions/attributes...] (model Post ...).
    class NamedBase < Base
      @name : String = ""

      def generate : Nil
        @name = args[0]? || abort(usage)
      end

      def usage : String
        "Usage: crails generate #{self.class.generator_name} NAME"
      end

      # "Admin::User" -> ["admin"]
      def class_path : Array(String)
        parts = @name.split("::")
        parts[0..-2].map(&.underscore)
      end

      # "Admin::User" -> "User" (normalized through underscore so names like
      # UserMailer keep their acronym separation: UserMailer -> user_mailer)
      def class_name : String
        singular_name.camelize
      end

      # "Admin::User" -> "user"
      def singular_name : String
        @name.split("::").last.underscore
      end

      # "Admin::User" -> "admin/user"
      def file_path : String
        (class_path + [singular_name]).join("/")
      end

      # "Admin::User" -> "admin_users"
      def table_name : String
        (class_path + [singular_name.pluralize]).join("_")
      end

      # "Admin::User" -> "Admin::User"; "UserMailer" stays "UserMailer"
      # (normalized through underscore so capitalize never glues acronyms).
      def full_class_name : String
        @name.split("::").map(&.underscore.camelize).join("::")
      end

      # "Admin::User" -> "Admin"
      def module_name : String
        class_path.map(&.camelize).join("::")
      end

      # Remaining positional args (actions for controllers, attrs otherwise).
      def raw_attributes : Array(String)
        args[1..]
      end
    end
  end
end

require "file_utils"
