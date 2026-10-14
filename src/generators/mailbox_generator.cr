# `crails generate mailbox NAME` — 1:1 with Rails MailboxGenerator
# (oracle: mailbox_basic): mailbox + application_mailbox + spec.
# Deviation: process instead of Rails' Mailbox#process (CRails ActionMailbox
# uses process as the receiving hook).

module CRails
  module Generators
    class MailboxGenerator < NamedBase
      def generate : Nil
        super
        mailbox_file = File.join("app", "mailboxes", "#{file_path}_mailbox.cr")
        return if check_class_collision(mailbox_file, "#{full_class_name}Mailbox")

        create_file(mailbox_file, <<-CODE + "\n")
          class #{full_class_name}Mailbox < ApplicationMailbox
            def process
            end
          end
          CODE
        create_file(File.join("app", "mailboxes", "application_mailbox.cr"),
          <<-CODE + "\n")
          class ApplicationMailbox < ActionMailbox::Base
            # routing /something/i => :somewhere
          end
          CODE

        invoke("spec") do
          create_file(File.join("spec", "mailboxes", "#{file_path}_mailbox_spec.cr"),
            <<-CODE + "\n")
            require "spec_helper"

            describe #{full_class_name}Mailbox do
              # test "processes inbound email" do
              #   assert true
              # end
            end
            CODE
        end

        AppGlue.ensure_shard(self, "action_mailbox_cr")
        AppGlue.ensure_active_storage_tables(self)
        AppGlue.patch_requires(self, "app/mailboxes")
      end

      def usage : String
        "Usage: crails generate mailbox NAME"
      end
    end
  end
end
