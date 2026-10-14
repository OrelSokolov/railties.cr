# `crails generate controller NAME [actions]` — 1:1 with Rails
# ControllerGenerator (oracle: controller_* cases): controller + routes +
# views per action + spec + helper.
# Deviations: routes carry an explicit `to:` target (the CRails router has
# no positional-default routes); spec skeletons instead of minitest URL
# helper tests.

module CRails
  module Generators
    class ControllerGenerator < NamedBase
      def generate : Nil
        super
        actions = raw_attributes
        controller_file = File.join("app", "controllers", "#{file_path}_controller.cr")
        return if check_class_collision(controller_file, "#{full_class_name}Controller")

        create_file(controller_file, controller_body(actions))

        unless actions.empty? || !option?("route")
          route(actions.map { |a| %(get "#{file_path}/#{a}", to: "#{file_path}##{a}") })
        end

        invoke("erb") do
          create_dir(File.join("app", "views", file_path))
          actions.each do |action|
            create_file(File.join("app", "views", file_path, "#{action}.html.erb"),
              view_body(action))
          end
        end

        invoke("spec") do
          create_file(File.join("spec", "controllers", "#{file_path}_controller_spec.cr"),
            spec_body(actions))
        end

        invoke("helper") do
          create_file(File.join("app", "helpers", "#{file_path}_helper.cr"),
            <<-CODE + "\n")
            module #{full_class_name}Helper
            end
            CODE
          invoke("spec")
        end

        # Rails: генератор контроллера кладёт app/assets/stylesheets/<name>.css
        create_file(File.join("app", "assets", "stylesheets", "#{file_path}.css"),
          "/* Styles for #{full_class_name}#controller. */\n")

        AppGlue.patch_requires(self, "app/controllers")
        AppGlue.patch_requires(self, "app/helpers")
      end

      private def controller_body(actions : Array(String)) : String
        methods = actions.map { |a| "  def #{a}\n  end" }.join("\n\n")
        sep = actions.empty? ? "" : "\n"
        "class #{full_class_name}Controller < ApplicationController\n#{methods}#{sep}end\n"
      end

      private def view_body(action : String) : String
        <<-ERB + "\n"
          <h1>#{full_class_name}##{action}</h1>
          <p>Find me in app/views/#{file_path}/#{action}.html.erb</p>
          ERB
      end

      private def spec_body(actions : Array(String)) : String
        tests = actions.map do |a|
          "  # test \"should get #{a}\" do\n" \
          "  #   get \"/#{file_path}/#{a}\"\n" \
          "  #   assert_response :success\n" \
          "  # end"
        end.join("\n\n")
        sep = actions.empty? ? "" : "\n"
        "require \"spec_helper\"\n\ndescribe #{full_class_name}Controller do#{sep}#{tests}#{sep}end\n"
      end

      def usage : String
        "Usage: crails generate controller NAME [action ...]"
      end
    end
  end
end
