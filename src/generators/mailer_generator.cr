# `crails generate mailer NAME [actions]` — 1:1 with Rails MailerGenerator
# (oracle: mailer_basic): mailer + text/html views per action + spec.
# Deviations: spec file instead of minitest test/preview files;
# app/mailers/application_mailer.cr is bootstrapped when missing (the
# Iteration-0 `crails new` skeleton has no app/mailers yet).

module CRails
  module Generators
    class MailerGenerator < NamedBase
      def generate : Nil
        super
        mailer_file = File.join("app", "mailers", "#{file_path}.cr")
        return if check_class_collision(mailer_file, full_class_name)

        unless File.exists?(File.join("app", "mailers", "application_mailer.cr"))
          create_file(File.join("app", "mailers", "application_mailer.cr"),
            <<-CODE + "\n")
            class ApplicationMailer < ActionMailer::Base
              default from: "from@example.com"
              # layout "mailer"
            end
            CODE
        end

        create_file(mailer_file, mailer_body)

        invoke("erb") do
          create_dir(File.join("app", "views", file_path))
          raw_attributes.each do |action|
            create_file(File.join("app", "views", file_path, "#{action}.text.erb"),
              text_view(action))
            create_file(File.join("app", "views", file_path, "#{action}.html.erb"),
              html_view(action))
          end
        end

        invoke("spec") do
          create_file(File.join("spec", "mailers", "#{file_path}_spec.cr"),
            <<-CODE + "\n")
            require "spec_helper"

            describe #{full_class_name} do
              # test "welcome" do
              #   assert true
              # end
            end
            CODE
        end

        AppGlue.ensure_shard(self, "action_mailer_cr")
        AppGlue.patch_requires(self, "app/mailers")
      end

      private def mailer_body : String
        actions = raw_attributes.map do |action|
          "  # Subject can be set in your I18n file at config/locales/en.yml\n" \
          "  # with the following lookup:\n" \
          "  #\n" \
          "  #   en.#{file_path.gsub("/", ".")}.#{action}.subject\n" \
          "  #\n" \
          "  def #{action}\n" \
          "    @greeting = \"Hi\"\n" \
          "\n" \
          "    mail(to: \"to@example.com\")\n" \
          "  end"
        end.join("\n\n")
        sep = raw_attributes.empty? ? "" : "\n"
        "class #{full_class_name} < ApplicationMailer\n#{actions}#{sep}end\n"
      end

      private def mailer_display : String
        # Rails shows the mailer as "User" (class name minus Mailer) in
        # generated views.
        name = class_name
        name = name[0...-6] if name.ends_with?("Mailer")
        (class_path + [name]).join("#")
      end

      private def text_view(action : String) : String
        <<-ERB + "\n"
          #{mailer_display}##{action}

          <%= @greeting %>, find me in app/views/#{file_path}/#{action}.text.erb
          ERB
      end

      private def html_view(action : String) : String
        <<-ERB + "\n"
          <h1>#{mailer_display}##{action}</h1>

          <p>
            <%= @greeting %>, find me in app/views/#{file_path}/#{action}.html.erb
          </p>
          ERB
      end

      def usage : String
        "Usage: crails generate mailer NAME [action ...]"
      end
    end
  end
end
