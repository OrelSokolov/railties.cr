# App glue — CRails apps compile every app/ dir explicitly (no zeitwerk),
# so generators patch src/app.cr with the requires for the dirs they touch.
# Printed as a thor-style `patch` line (documented CRails extension).

module CRails
  module Generators
    module AppGlue
      # require order: models before controllers (controllers use models),
      # then the leaf dirs.
      ORDER = {"app/models", "app/controllers", "app/jobs", "app/mailers",
               "app/channels", "app/mailboxes", "app/bots", "app/helpers"}

      def self.patch_requires(gen : Base, dir : String) : Nil
        return unless Dir.exists?(dir.split('/').first)
        path = File.join("src", "app.cr")
        return unless File.exists?(path)
        src = File.read(path)
        req = %(require "../#{dir}/**")
        return if src.includes?(req)

        lines = src.lines(chomp: true)
        rank = ORDER.index(dir) || ORDER.size

        # Positions of the existing app/ requires (keeps the ORDER priority:
        # models must compile before the controllers that reference them).
        app_positions = lines.each_index.select { |i|
          lines[i].starts_with?(%(require "../app/))
        }.to_a

        insert_at =
          if lower = app_positions.find { |i|
               existing = lines[i][%r{require "\.\./app/([a-z_]+)/}, 1]? || ""
               (ORDER.index("app/#{existing}") || ORDER.size) > rank
             }
            lower
          elsif !app_positions.empty?
            app_positions.last + 1
          else
            (lines.rindex { |l| l.starts_with?("require ") } || -1) + 1
          end

        lines.insert(insert_at, req)
        gen.say("patch", path)
        File.write(path, lines.join('\n') + "\n") unless gen.pretend?
      end

      # CRails deviation standing in for `rails active_storage:install`:
      # model codegen reads db/schema.yml of the app, so a mailbox app
      # (which compiles active_storage) needs the two framework tables.
      # Idempotent: skipped when an install migration already exists.
      def self.ensure_active_storage_tables(gen : Base) : Nil
        return unless Dir.exists?(File.join("db", "migrate"))
        return if Dir.glob(File.join("db", "migrate", "*_create_active_storage_tables.cr")).any?

        gen.create_file(File.join("db", "migrate", Base.migration_filename("create_active_storage_tables")),
          <<-CODE + "\n")
          class CreateActiveStorageTables < ActiveRecord::Migration
            def change
              create_table :active_storage_blobs do |t|
                t.string :key, null: false
                t.string :filename, null: false
                t.string :content_type
                t.text :metadata
                t.string :service_name, null: false
                t.bigint :byte_size, null: false
                t.string :checksum
                t.timestamps
              end
              add_index :active_storage_blobs, :key, unique: true

              create_table :active_storage_attachments do |t|
                t.string :name, null: false
                t.string :record_type, null: false
                t.bigint :record_id, null: false
                t.bigint :blob_id, null: false
                t.timestamps
              end
              add_index :active_storage_attachments, [:record_type, :record_id], name: "index_active_storage_attachments_on_record"
              add_index :active_storage_attachments, :blob_id
            end
          end
          CODE
      end

      # Insert `req` immediately before an existing require line. Channels
      # need it: `Dir["app/channels/**"]` yields root files before the
      # application_cable/ subdir, so the base classes must be required
      # explicitly first.
      def self.require_before(gen : Base, existing : String, req : String) : Nil
        path = File.join("src", "app.cr")
        return unless File.exists?(path)
        src = File.read(path)
        return if src.includes?(req)
        lines = src.lines(chomp: true)
        idx = lines.index(existing)
        return unless idx
        lines.insert(idx, req)
        gen.say("patch", path)
        File.write(path, lines.join('\n') + "\n") unless gen.pretend?
      end

      # Models compile against active_record_cr and need a DB connection
      # at boot (the Iteration-0 skeleton has neither — model/scaffold
      # generators add both to src/app.cr, like the demo app does).
      def self.ensure_active_record(gen : Base) : Nil
        path = File.join("src", "app.cr")
        return unless File.exists?(path)
        src = File.read(path)
        changed = false

        unless src.includes?(%(require "active_record_cr"))
          src = src.sub(%(require "railties_cr"\n),
            %(require "railties_cr"\nrequire "active_record_cr"\n))
          changed = true
        end

        unless src.includes?("establish_connection")
          anchor = "CRails.application.initialize!"
          block = <<-CODE
            if (url = ENV["DATABASE_URL"]?)
              ActiveRecord::Base.establish_connection(url)
            elsif File.exists?("config/database.yml")
              ActiveRecord::Base.establish_connection_from_yaml(
                "config/database.yml", CRails.env.to_s.downcase)
            end

            CODE
          src = src.sub(anchor, block + anchor)
          changed = true
        end

        return unless changed
        gen.say("patch", path)
        File.write(path, src) unless gen.pretend?
      end

      # Framework shards used by the leaf generators (job/channel/mailbox/
      # mailer): symlink into lib/ (dev monorepo mode, like `crails new`
      # and `crails generate bot` do) and add the require to src/app.cr.
      # Values carry their transitive monorepo deps (mailbox needs
      # active_storage at compile time).
      SHARDS = {
        "active_job_cr"     => {"active_job.cr"},
        "action_cable_cr"   => {"action_cable.cr"},
        "action_mailer_cr"  => {"action_mailer.cr"},
        "action_mailbox_cr" => {"action_mailbox.cr", "active_storage.cr"},
      }

      # Extra glue beyond the bare require: the mailers previews UI
      # (/rails/mailers, the analog of ActionMailer::Railtie's routes —
      # railties_cr does not depend on action_mailer_cr, so the endpoint
      # self-registers in CRails.dev_endpoints). Preview classes live in
      # spec/mailers/previews/ (glob require is a no-op until created).
      SNIPPETS = {
        "action_mailer_cr" => %(require "action_mailer_cr"
require "../spec/mailers/previews/**"
CRails.dev_endpoints["/rails/mailers"] = ->(ctx : HTTP::Server::Context) { ActionMailer::PreviewServer.serve?(ctx) }),
      }

      def self.ensure_shard(gen : Base, shard : String) : Nil
        return unless deps = SHARDS[shard]?

        exe = Process.executable_path
        railties_dir = exe ? File.dirname(File.dirname(exe)) : nil
        repo_root = railties_dir ? File.dirname(railties_dir.not_nil!) : nil
        target = repo_root ? File.join(repo_root.not_nil!, SHARDS[shard][0]) : nil
        if target && File.exists?(target)
          deps.each do |dep|
            name = dep.chomp(".cr") + "_cr"
            link = File.join("lib", name)
            next if File.exists?(link)
            dep_target = File.join(repo_root.not_nil!, dep)
            next unless File.exists?(dep_target)
            FileUtils.mkdir_p("lib")
            gen.say("symlink", "lib/#{name}")
            File.symlink(dep_target, link) unless gen.pretend?
          end
        end

        path = File.join("src", "app.cr")
        return unless File.exists?(path)
        src = File.read(path)
        req = SNIPPETS[shard]? || %(require "#{shard}")
        return if src.includes?(req)
        anchor = %(require "railties_cr"\n)
        return unless src.includes?(anchor)
        src = src.sub(anchor, %(require "railties_cr"\n#{req}\n))
        gen.say("patch", path)
        File.write(path, src) unless gen.pretend?
      end
    end
  end
end
