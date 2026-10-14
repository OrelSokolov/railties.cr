#!/usr/bin/env ruby
# Oracle: per-environment credentials + tmp/local_secret.txt (Rails 8.1.4,
# railties application/configuration.rb: credentials_defaults and
# generate_local_secret / secret_key_base resolution order). Runs the real
# Rails app from devise.cr/tmp/http_app and prints "<case>\t<value>" lines
# for spec/credentials_spec.cr; the captured output lives in
# oracle/credentials_env_expected.yml.
#
# Usage (rvm ruby with rails 8.1.4 on GEM_HOME/GEM_PATH):
#   ruby oracle/credentials_env_cases.rb > oracle/credentials_env_expected.yml

ENV.delete("RAILS_MASTER_KEY")
ENV.delete("SECRET_KEY_BASE")
ENV.delete("SECRET_KEY_BASE_DUMMY")

gem "activesupport", "= 8.1.4"
require "active_support/encrypted_file"
require "fileutils"

APP = File.expand_path("../../devise.cr/tmp/http_app", __dir__)
FIXTURES = File.expand_path("fixtures/credentials", __dir__)

PROD_KEY = "e3b0c44298fc1c149afbf4c8996fb924"
ENV_CONTENT = <<~YAML
  secret_key_base: prod_skb_1a2b3c4d5e6f
  database:
    password: env_orangutan
YAML

CREDS_DIR  = File.join(APP, "config", "credentials")
PROD_ENC   = File.join(CREDS_DIR, "production.yml.enc")
PROD_KEY_P = File.join(CREDS_DIR, "production.key")
MASTER_KEY = File.join(APP, "config", "master.key")
GLOBAL_ENC = File.join(APP, "config", "credentials.yml.enc")
LOCAL_SEC  = File.join(APP, "tmp", "local_secret.txt")

PROD      = {"RAILS_ENV" => "production"}
PROD_EKEY = {"RAILS_ENV" => "production", "RAILS_MASTER_KEY" => PROD_KEY}
DEV_EKEY  = {"RAILS_ENV" => "development", "RAILS_MASTER_KEY" => PROD_KEY}

def emit(id, value)
  puts "#{id}\t#{value}"
end

# `bin/rails runner CODE` in a controlled env; returns [success?, output].
def runner(code, env = {})
  full = {
    "GEM_HOME" => ENV.fetch("GEM_HOME"),
    "GEM_PATH" => ENV.fetch("GEM_PATH"),
    "PATH"     => ENV.fetch("PATH"),
  }.merge(env)
  out = IO.popen(full, [File.join(APP, "bin", "rails"), "runner", code],
                chdir: APP, err: [:child, :out], &:read)
  [$?.success?, out]
end

def hide(path)
  FileUtils.mv(path, "#{path}.ora-hidden") if File.exist?(path)
end

def restore(path)
  h = "#{path}.ora-hidden"
  FileUtils.mv(h, path) if File.exist?(h)
end

begin
  # --- fixture: env credentials written by the real gem ---------------
  FileUtils.mkdir_p(CREDS_DIR)
  File.write(PROD_KEY_P, PROD_KEY)
  ActiveSupport::EncryptedFile.new(
    content_path: PROD_ENC, key_path: PROD_KEY_P,
    env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true
  ).write(ENV_CONTENT)

  # keep a copy for the port fixtures directory
  FileUtils.cp(PROD_ENC, File.join(FIXTURES, "production.yml.enc"))
  FileUtils.cp(PROD_KEY_P, File.join(FIXTURES, "production.key"))

  # --- cases: env-specific files win when present ---------------------
  _, out = runner(<<~'CODE', PROD)
    c = Rails.application.config.credentials
    puts c.content_path.basename.to_s
    puts c.key_path.basename.to_s
    puts Rails.application.credentials.dig(:database, :password).to_s
    puts Rails.application.credentials.secret_key_base.to_s
    puts Rails.application.secret_key_base.to_s
  CODE
  emit("envc_paths", out.lines[0..1].map(&:strip).join(","))
  emit("envc_read", out.lines[2].strip)
  emit("envc_skb", out.lines[3].strip)
  emit("envc_app_skb", out.lines[4].strip)

  # SECRET_KEY_BASE env wins over credentials
  _, out = runner(<<~'CODE', {"RAILS_ENV" => "production", "SECRET_KEY_BASE" => "from-env"})
    puts Rails.application.secret_key_base
  CODE
  emit("envc_env_precedence", out.strip)

  # RAILS_MASTER_KEY decrypts the env file without any key files
  hide(PROD_KEY_P)
  _, out = runner(<<~'CODE', PROD_EKEY)
    puts Rails.application.credentials.dig(:database, :password)
  CODE
  emit("envc_envkey_read", out.strip)

  # no key anywhere: app credentials have raise_if_missing_key = false
  # (require_master_key is off), so key? is false, read == "" and
  # secret_key_base is nil (development -> tmp/local_secret.txt fallback)
  hide(MASTER_KEY)
  _, out = runner(<<~'CODE', {"RAILS_ENV" => "development"})
    puts Rails.application.credentials.key?
    puts Rails.application.credentials.read.inspect
    puts Rails.application.credentials.secret_key_base.nil?
    puts Rails.application.config.credentials.key_path.basename.to_s
  CODE
  emit("envc_nokey_key", out.lines[0].strip)
  emit("envc_nokey_read", out.lines[1].strip)
  emit("envc_nokey_skb_nil", out.lines[2].strip)
  emit("envc_nokey_keypath", out.lines[3].strip)

  restore(MASTER_KEY)

  # no env files -> global fallback paths and global content
  hide(PROD_ENC)
  _, out = runner(<<~'CODE', PROD)
    c = Rails.application.config.credentials
    puts c.content_path.basename.to_s
    puts c.key_path.basename.to_s
    puts Rails.application.credentials.read.empty?
    begin
      puts Rails.application.credentials.dig(:database, :password).to_s
    rescue
      puts "NO-SUCH-KEY"
    end
  CODE
  emit("envc_fb_paths", out.lines[0..1].map(&:strip).join(","))
  emit("envc_fb_read_empty", out.lines[2].strip)
  emit("envc_fb_read", out.lines[3].strip)

  # key present (ENV) but no content file anywhere -> read == "" and skb nil
  hide(GLOBAL_ENC)
  _, out = runner(<<~'CODE', DEV_EKEY)
    puts Rails.application.credentials.read.inspect
    puts Rails.application.credentials.secret_key_base.nil?
  CODE
  emit("envc_nofile_read", out.lines[0].strip)
  emit("envc_nofile_skb_nil", out.lines[1].strip)

  # development with no credentials at all -> tmp/local_secret.txt
  hide(GLOBAL_ENC)
  _, out = runner(<<~'CODE', {"RAILS_ENV" => "development"})
    s1 = Rails.application.secret_key_base
    s2 = Rails.application.secret_key_base
    puts s1 == s2
    puts s1.length
    puts File.exist?(Rails.root.join("tmp/local_secret.txt"))
    puts Rails.application.config.credentials.content_path.basename.to_s
  CODE
  emit("envc_local_stable", out.lines[0].strip)
  emit("envc_local_len", out.lines[1].strip)
  emit("envc_local_file", out.lines[2].strip)
  emit("envc_local_paths", out.lines[3].strip)

  # SECRET_KEY_BASE_DUMMY forces the local secret in production
  _, out = runner(<<~'CODE', {"RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1"})
    s = Rails.application.secret_key_base
    puts File.exist?(Rails.root.join("tmp/local_secret.txt"))
    puts s.length
    puts s == File.read(Rails.root.join("tmp/local_secret.txt")).strip
  CODE
  emit("envc_dummy_file", out.lines[0].strip)
  emit("envc_dummy_len", out.lines[1].strip)
  emit("envc_dummy_matches", out.lines[2].strip)
ensure
  # --- teardown: leave http_app exactly as it was ----------------------
  [PROD_ENC, PROD_KEY_P, MASTER_KEY, GLOBAL_ENC].each { |p| restore(p) }
  FileUtils.rm_rf(CREDS_DIR) if File.directory?(CREDS_DIR)
  File.delete(LOCAL_SEC) if File.exist?(LOCAL_SEC)
end
