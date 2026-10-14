# Shared model-file creation (model generator + scaffold composition):
# migration, model class, namespace module, spec + fixture — the
# `active_record`/`spec` invoke blocks 1:1 with the Rails oracle.

module CRails
  module Generators
    module ModelFiles
      def create_model_files(gen : NamedBase, fields : Array(Field)) : Nil
        AppGlue.ensure_active_record(gen)

        if gen.option?("migration")
          if gen.behavior == :revoke
            # the generate-time timestamp is gone — remove by name pattern
            Dir.glob(File.join("db", "migrate", "*_create_#{gen.table_name}.cr"))
              .each { |f| gen.create_file(f, "") }
          else
            file_name = Base.migration_filename("create_#{gen.table_name}")
            class_name = "Create#{(gen.class_path + [gen.table_name]).map(&.camelize).join}"
            content = MigrationBuilder.build(class_name, fields, gen.table_name,
              gen.option?("timestamps"))
            gen.create_file(File.join("db", "migrate", file_name), content)
          end
        end

        gen.create_file(File.join("app", "models", "#{gen.file_path}.cr"),
          model_body(gen, fields))

        unless gen.class_path.empty?
          gen.create_file(File.join("app", "models", "#{gen.class_path.join("/")}.cr"),
            <<-CODE + "\n")
            module #{gen.module_name}
              def self.table_name_prefix
                "#{gen.class_path.join("_")}_"
              end
            end
            CODE
        end

        gen.invoke("spec") do
          gen.create_file(File.join("spec", "models", "#{gen.file_path}_spec.cr"),
            <<-CODE + "\n")
            require "spec_helper"

            describe #{gen.full_class_name} do
              # test "the truth" do
              #   assert true
              # end
            end
            CODE
          if gen.option?("fixture")
            fixture_path = (gen.class_path + [gen.singular_name.pluralize]).join("/")
            gen.create_file(File.join("spec", "fixtures", "#{fixture_path}.yml"),
              fixture_body(fields))
          end
        end
      end

      private def model_body(gen : NamedBase, fields : Array(Field)) : String
        associations = fields.select(&.reference?).map do |f|
          poly = f.polymorphic? ? ", polymorphic: true" : ""
          "  belongs_to :#{f.name}#{poly}\n"
        end.join
        "class #{gen.full_class_name} < ApplicationRecord\n#{associations}end\n"
      end

      private def fixture_body(fields : Array(Field)) : String
        body = fields.map { |f| fixture_line(f, "one") }.join
        two = fields.map { |f| fixture_line(f, "two") }.join
        header = "# Read about fixtures at https://api.rubyonrails.org/classes/ActiveRecord/FixtureSet.html\n\n"
        header + "one:\n#{body}two:\n#{two}"
      end

      private def fixture_line(f : Field, label : String) : String
        if f.reference?
          if f.polymorphic?
            "  #{f.name}: #{label}\n  #{f.name}_type: #{f.name.camelize}\n"
          else
            "  #{f.name}: #{label}\n"
          end
        else
          "  #{f.name}: #{f.fixture_value}\n"
        end
      end
    end
  end
end
