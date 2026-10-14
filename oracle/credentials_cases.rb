# Oracle cases for CRails credentials (Phase B) — the Rails 8.1.4
# wire of config/credentials.yml.enc.
#
# Run against the ORIGINAL gems:
#   ruby oracle/credentials_cases.rb > oracle/credentials_expected.yml
#
# Writes fixtures into oracle/fixtures/credentials/ (master.key +
# credentials.yml.enc produced by the real ActiveSupport::EncryptedFile
# with a pinned key) — the port spec replays them byte-exact; the
# reverse direction (port-written file read back here) is
# oracle/verify_credentials.rb.
#
# Wire facts pinned by this oracle:
#   * cipher aes-128-gcm (EncryptedFile::CIPHER), key = hex(master.key)
#     unpacked to bytes (pack("H*"));
#   * envelope: legacy 3-part strict-base64 iv--ciphertext--auth_tag
#     (serializer Marshal + no purpose -> no _rails/ JSON envelope);
#   * inner plaintext = Marshal.dump(String) of the YAML document;
#   * missing key -> ActiveSupport::EncryptedFile::MissingKeyError,
#     wrong key -> ActiveSupport::MessageEncryptor::InvalidMessage.

gem "activesupport", "= 8.1.4"
gem "railties", "= 8.1.4"
require "active_support/encrypted_file"
require "active_support/message_encryptor"
require "fileutils"

def line(id, value)
  puts "#{id}\t#{value.inspect}"
end

FIXTURES = File.expand_path("fixtures/credentials", __dir__)
FileUtils.mkdir_p(FIXTURES)

KEY_HEX = "1f7d2b983e4b4ad7a29b9b574f46a046" # 32 hex chars = 16 bytes (aes-128)

YAML_CONTENT = <<~YAML
  secret_key_base: 6a1c7f75a2b4f0e4d6c8e9f0a1b2c3d4
  database:
    password: orangutan
  aws:
    access_key_id: AKIAEXAMPLE
YAML

content_path = File.join(FIXTURES, "credentials.yml.enc")
key_path = File.join(FIXTURES, "master.key")

File.write(key_path, KEY_HEX)

file = ActiveSupport::EncryptedFile.new(
  content_path: content_path, key_path: key_path,
  env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true)
file.write(YAML_CONTENT)

line("cred_wire_format", File.read(content_path).include?("--"))

# decryption via a fresh EncryptedFile (reads key from key_path)
fresh = ActiveSupport::EncryptedFile.new(
  content_path: content_path, key_path: key_path,
  env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true)
content = fresh.read
line("cred_roundtrip", content == YAML_CONTENT)
line("cred_secret_key_base", content[/secret_key_base: (\S+)/, 1])

# missing key -> MissingKeyError (env cleared, key file missing)
ENV.delete("RAILS_MASTER_KEY")
missing = ActiveSupport::EncryptedFile.new(
  content_path: content_path,
  key_path: File.join(FIXTURES, "nope.key"),
  env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true)
begin
  missing.read
  line("cred_missing_key", "no-error")
rescue ActiveSupport::EncryptedFile::MissingKeyError => e
  line("cred_missing_key_class", e.class.name)
end

# wrong key -> InvalidMessage
File.write(File.join(FIXTURES, "wrong.key"), "0" * 32)
wrong = ActiveSupport::EncryptedFile.new(
  content_path: content_path,
  key_path: File.join(FIXTURES, "wrong.key"),
  env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true)
begin
  wrong.read
  line("cred_wrong_key", "no-error")
rescue ActiveSupport::MessageEncryptor::InvalidMessage => e
  line("cred_wrong_key_class", e.class.name)
end

# ENV key wins over the key file
ENV["RAILS_MASTER_KEY"] = KEY_HEX
envkey = ActiveSupport::EncryptedFile.new(
  content_path: content_path,
  key_path: File.join(FIXTURES, "nope.key"),
  env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true)
line("cred_env_key", envkey.read == YAML_CONTENT)
ENV.delete("RAILS_MASTER_KEY")

# key length validation
begin
  File.write(File.join(FIXTURES, "short.key"), "0" * 31)
  short = ActiveSupport::EncryptedFile.new(
    content_path: content_path,
    key_path: File.join(FIXTURES, "short.key"),
    env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true)
  short.read
  line("cred_short_key", "no-error")
rescue => e
  # 31-hex key packs to 15 bytes -> encryptor failure (no length check
  # in EncryptedFile itself; Rails' railtie adds one in apps)
  line("cred_short_key_class", e.class.name)
end
