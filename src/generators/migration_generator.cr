# `crails generate migration NAME [fields]` — 1:1 with Rails
# MigrationGenerator (oracle: mig_* cases). The migration file name is
# NAME underscored + UTC timestamp prefix, like Rails.

module CRails
  module Generators
    class MigrationGenerator < NamedBase
      def generate : Nil
        super
        fields = parse_fields
        if behavior == :revoke
          # the generate-time timestamp is gone — remove by name pattern
          invoke("active_record") do
            Dir.glob(File.join("db", "migrate", "*_#{@name.underscore}.cr"))
              .each { |f| create_file(f, "") }
          end
          return
        end
        file_name = Base.migration_filename(@name.underscore)
        content = MigrationBuilder.build(@name, fields)
        invoke("active_record") do
          create_file(File.join("db", "migrate", file_name), content)
        end
      end

      private def parse_fields : Array(Field)
        Fields.parse_all(raw_attributes)
      rescue e : Fields::UnknownFieldType
        name, type = e.field.split(':', 2)
        STDERR.puts "Could not generate field '#{name}' with unknown type '#{type}'."
        exit 0
      end

      def usage : String
        "Usage: crails generate migration NAME [field:type ...]"
      end
    end
  end
end
