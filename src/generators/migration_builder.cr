# Migration content builder — shared by the migration and model generators.
# Mirrors Rails' MigrationGenerator/CreateMigrationFile output byte-for-byte
# (oracle: oracle/generators_expected.yml), modulo the documented deviations:
# `ActiveRecord::Migration` (CRails has no versioned migration base).

module CRails
  module Generators
    module MigrationBuilder
      # `CreatePosts` / `AddTitleToPosts` / `RemoveTitleFromPosts` ...
      def self.build(class_name : String, fields : Array(Field),
                     table_name : String? = nil, timestamps = true) : String
        body =
          if class_name.starts_with?("CreateJoinTable")
            "" # join tables: Rails 8.1 leaves these empty too (oracle mig_join)
          elsif class_name.starts_with?("Create")
            tbl = table_name || class_name[6..].underscore.pluralize
            create_table_body(tbl, fields, timestamps)
          elsif (m = class_name.match(/^Add(\w+)To(\w+)$/))
            tbl = table_name || m[2].underscore
            add_columns_body(tbl, fields)
          elsif (m = class_name.match(/^Remove(\w+)From(\w+)$/))
            tbl = table_name || m[2].underscore
            remove_columns_body(tbl, fields)
          else
            "" # empty change (RenameXxxToYyyOnZzz etc. — Rails leaves it empty too)
          end

        <<-CODE + "\n"
          class #{class_name} < ActiveRecord::Migration
            def change
          #{body}  end
          end
          CODE
      end

      def self.create_table_body(table : String, fields : Array(Field),
                                 timestamps : Bool) : String
        cols = fields.reject(&.reference?).map { |f| "      #{column_line(f)}\n" }.join
        refs = fields.select(&.reference?).map { |f| "      #{reference_line(f)}\n" }.join
        indexes = fields.select(&.index?).map { |f| index_line(table, f) }.compact
        uniqs = fields.select(&.uniq?).map { |f| index_line(table, f) }.compact

        out = ""
        out += "    create_table :#{table} do |t|\n"
        out += cols
        out += "\n" unless cols.empty? || refs.empty?
        out += refs
        out += "\n" if !cols.empty? || !refs.empty?
        out += "      t.timestamps\n" if timestamps
        out += "    end\n"
        out += (indexes + uniqs).map { |l| "    #{l}\n" }.join
        out
      end

      def self.add_columns_body(table : String, fields : Array(Field)) : String
        out = ""
        indexes = [] of String
        fields.each do |f|
          if f.reference?
            out += "    #{add_reference_line(table, f)}\n"
          else
            out += "    add_column :#{table}, :#{f.name}, :#{f.type}#{modifiers(f)}\n"
          end
          if idx = index_line(table, f)
            indexes << "    #{idx}\n"
          end
        end
        out + indexes.join
      end

      def self.remove_columns_body(table : String, fields : Array(Field)) : String
        fields.map do |f|
          if f.reference?
            "    remove_reference :#{table}, :#{f.name}, null: false, foreign_key: true\n"
          else
            "    remove_column :#{table}, :#{f.name}, :#{f.type}\n"
          end
        end.join
      end

      def self.column_line(f : Field) : String
        "t.#{f.type} :#{f.name}#{modifiers(f)}"
      end

      def self.modifiers(f : Field) : String
        mods = [] of String
        mods << "limit: #{f.limit}" if f.limit
        if f.precision
          mods << "precision: #{f.precision}"
          mods << "scale: #{f.scale}" if f.scale
        end
        mods.empty? ? "" : ", #{mods.join(", ")}"
      end

      def self.reference_line(f : Field) : String
        mods = [] of String
        mods << "polymorphic: true" if f.polymorphic?
        mods << "null: false"
        mods << "foreign_key: true" unless f.polymorphic?
        "t.references :#{f.name}, #{mods.join(", ")}"
      end

      def self.add_reference_line(table : String, f : Field) : String
        mods = [] of String
        mods << "polymorphic: true" if f.polymorphic?
        mods << "null: false"
        mods << "foreign_key: true" unless f.polymorphic?
        "add_reference :#{table}, :#{f.name}, #{mods.join(", ")}"
      end

      def self.index_line(table : String, f : Field) : String?
        return nil unless f.index? || f.uniq?
        suffix = f.uniq? ? ", unique: true" : ""
        "add_index :#{table}, :#{f.name}#{suffix}"
      end
    end
  end
end
