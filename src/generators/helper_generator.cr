# `crails generate helper NAME` — 1:1 with Rails HelperGenerator
# (oracle: helper_basic): module file + `invoke spec` (test_unit prints no
# spec file in Rails; CRails mirrors the invoke line only).

module CRails
  module Generators
    class HelperGenerator < NamedBase
      def generate : Nil
        super
        helper_file = File.join("app", "helpers", "#{file_path}_helper.cr")
        return if check_class_collision(helper_file, "#{full_class_name}Helper")
        create_file(helper_file, <<-CODE + "\n")
          module #{full_class_name}Helper
          end
          CODE
        invoke("spec")
        AppGlue.patch_requires(self, "app/helpers")
      end

      def usage : String
        "Usage: crails generate helper NAME"
      end
    end
  end
end
