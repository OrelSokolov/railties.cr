# `crails generate model NAME [fields]` — 1:1 with Rails ModelGenerator
# (oracle: model_* cases): migration + model + spec/fixture.
# Deviations: `spec/` instead of `test/` (spec files + fixtures),
# `ActiveRecord::Migration` base without the [8.1] version tag.

module CRails
  module Generators
    class ModelGenerator < NamedBase
      include ModelFiles

      def generate : Nil
        super
        fields = parse_fields

        invoke("active_record") do
          # class collision check (Rails prints the invoke line first,
          # then the warning stops the generator)
          return if check_class_collision(File.join("app", "models", "#{file_path}.cr"),
            full_class_name)
          create_model_files(self, fields)
        end

        AppGlue.patch_requires(self, "app/models")
      end

      private def parse_fields : Array(Field)
        Fields.parse_all(raw_attributes)
      rescue e : Fields::UnknownFieldType
        name, type = e.field.split(':', 2)
        STDERR.puts "Could not generate field '#{name}' with unknown type '#{type}'."
        exit 0
      end

      def usage : String
        "Usage: crails generate model NAME [field:type ...]"
      end
    end
  end
end
