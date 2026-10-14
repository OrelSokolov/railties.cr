# `crails generate channel NAME` — 1:1 with Rails ChannelGenerator
# (oracle: channel_basic): application_cable bootstrap + channel + spec.
# Deviation: no JS/importmap files (no asset pipeline in CRails).

module CRails
  module Generators
    class ChannelGenerator < NamedBase
      def generate : Nil
        super
        channel_file = File.join("app", "channels", "#{file_path}_channel.cr")
        return if check_class_collision(channel_file, "#{full_class_name}Channel")

        invoke("spec") do
          create_file(File.join("spec", "channels", "#{file_path}_channel_spec.cr"),
            <<-CODE + "\n")
            require "spec_helper"

            describe #{full_class_name}Channel do
              # test "subscribes" do
              #   assert true
              # end
            end
            CODE
        end

        cable_dir = File.join("app", "channels", "application_cable")
        unless File.exists?(File.join(cable_dir, "channel.cr"))
          create_file(File.join(cable_dir, "channel.cr"), <<-CODE + "\n")
            module ApplicationCable
              class Channel < ActionCable::Channel::Base
              end
            end
            CODE
          create_file(File.join(cable_dir, "connection.cr"), <<-CODE + "\n")
            module ApplicationCable
              # Deviation: the port exposes a concrete ActionCable::Connection
              # (fiber-per-connection endpoint), not Connection::Base.
              class Connection < ActionCable::Connection
              end
            end
            CODE
        end

        create_file(channel_file, <<-CODE + "\n")
          class #{full_class_name}Channel < ApplicationCable::Channel
            def subscribed
              # stream_from "some_channel"
            end

            def unsubscribed
              # Any cleanup needed when channel is unsubscribed
            end
          end
          CODE

        AppGlue.ensure_shard(self, "action_cable_cr")
        AppGlue.patch_requires(self, "app/channels")
        AppGlue.require_before(self, %(require "../app/channels/**"),
          %(require "../app/channels/application_cable/**"))
      end

      def usage : String
        "Usage: crails generate channel NAME"
      end
    end
  end
end
