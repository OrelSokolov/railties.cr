# `crails generate job NAME` — 1:1 with Rails JobGenerator (oracle:
# job_basic): spec file first, then app/jobs/NAME_job.cr.

module CRails
  module Generators
    class JobGenerator < NamedBase
      def generate : Nil
        super
        job_file = File.join("app", "jobs", "#{file_path}_job.cr")
        return if check_class_collision(job_file, "#{full_class_name}Job")

        # Bootstrap (the Iteration-0 `crails new` skeleton has no app/jobs).
        unless File.exists?(File.join("app", "jobs", "application_job.cr"))
          create_file(File.join("app", "jobs", "application_job.cr"),
            <<-CODE + "\n")
            class ApplicationJob < ActiveJob::Base
            end
            CODE
        end

        invoke("spec") do
          create_file(File.join("spec", "jobs", "#{file_path}_job_spec.cr"),
            <<-CODE + "\n")
            require "spec_helper"

            describe #{full_class_name}Job do
              # test "performs job" do
              #   assert true
              # end
            end
            CODE
        end

        create_file(job_file, <<-CODE + "\n")
          class #{full_class_name}Job < ApplicationJob
            queue_as :default

            def perform(*args)
              # Do something later
            end
          end
          CODE

        AppGlue.ensure_shard(self, "active_job_cr")
        AppGlue.patch_requires(self, "app/jobs")
      end

      def usage : String
        "Usage: crails generate job NAME"
      end
    end
  end
end
