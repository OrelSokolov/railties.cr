# Reverse verification for the credentials oracle (Phase B): reads a
# PORT-WRITTEN credentials file with the real ActiveSupport and prints
# "<case_id>\t<value>" lines the port spec asserts.
#
# Usage: ruby oracle/verify_credentials.rb <content_path> <key_path>

gem "activesupport", "= 8.1.4"
require "active_support/encrypted_file"

content_path, key_path = ARGV[0..1]
file = ActiveSupport::EncryptedFile.new(
  content_path: content_path, key_path: key_path,
  env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true)
content = file.read
puts "verify_readable\ttrue"
puts "verify_content\t#{content.inspect}"
