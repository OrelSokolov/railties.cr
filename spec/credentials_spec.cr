# Phase B spec — CRails::EncryptedConfiguration против оракула
# oracle/credentials_expected.yml (снят с activesupport 8.1.4,
# oracle/credentials_cases.rb; фикстуры oracle/fixtures/credentials
# сгенерированы реальным EncryptedFile с pinned-ключом). Реверс: спек
# пишет файл портом → oracle/verify_credentials.rb читает его гемом
# (Process.run, паттерн active_support.cr/spec/crypto_oracle_spec.cr).

require "spec"
require "yaml"
require "file_utils"
require "../src/railties_cr"

CRED_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/credentials_expected.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
    end
  end
  hash
end

FIXTURES = "#{__DIR__}/../oracle/fixtures/credentials"
KEY_HEX = "1f7d2b983e4b4ad7a29b9b574f46a046"
YAML_CONTENT = "secret_key_base: 6a1c7f75a2b4f0e4d6c8e9f0a1b2c3d4\n" \
               "database:\n  password: orangutan\n" \
               "aws:\n  access_key_id: AKIAEXAMPLE\n"

private def fixture_config(key_file = "master.key") : CRails::EncryptedConfiguration
  CRails::EncryptedConfiguration.new(
    content_path: File.join(FIXTURES, "credentials.yml.enc"),
    key_path: File.join(FIXTURES, key_file))
end

describe "MarshalStringCodec" do
  it "roundtrips strings of many lengths" do
    ["hello", "a" * 100, "a" * 122, "a" * 123, "a" * 128, "a" * 256,
     "a" * 300, "héllo"].each do |s|
      CRails::MarshalStringCodec.load(CRails::MarshalStringCodec.dump(s)).should eq s
    end
  end

  it "byte-matches ruby Marshal.dump framing" do
    # "\x04\bI\"\nhello\x06:\x06ET"
    dump = CRails::MarshalStringCodec.dump("hello")
    dump.bytes.should eq([0x04, 0x08, 0x49, 0x22, 0x0A] + "hello".bytes + [0x06, 0x3a, 0x06, 0x45, 0x54])
  end
end

describe "CRails::EncryptedConfiguration" do
  it "reads the gem-written fixture byte-exact (cred_roundtrip)" do
    fixture_config.read.should eq YAML_CONTENT
    (fixture_config.read == YAML_CONTENT).to_s.should eq CRED_EXPECTED["cred_roundtrip"]
  end

  it "uses the legacy 3-part wire (cred_wire_format)" do
    wire = File.read(File.join(FIXTURES, "credentials.yml.enc"))
    wire.includes?("--").to_s.should eq CRED_EXPECTED["cred_wire_format"]
  end

  it "digs values (cred_secret_key_base)" do
    value = fixture_config["secret_key_base"]?.try(&.as_s?)
    value.should eq "6a1c7f75a2b4f0e4d6c8e9f0a1b2c3d4"
    value.inspect.should eq CRED_EXPECTED["cred_secret_key_base"]
    fixture_config.dig("database", "password").try(&.as_s?).should eq "orangutan"
  end

  it "raises MissingKeyError without any key (cred_missing_key_class)" do
    ENV.delete("RAILS_MASTER_KEY")
    ENV.delete("CRAILS_MASTER_KEY")
    config = CRails::EncryptedConfiguration.new(
      content_path: File.join(FIXTURES, "credentials.yml.enc"),
      key_path: File.join(FIXTURES, "nope.key"))
    begin
      config.read
      fail("expected MissingKeyError")
    rescue ex : CRails::EncryptedConfiguration::MissingKeyError
      ex.class.name.should eq "CRails::EncryptedConfiguration::MissingKeyError"
      message = ex.message.should_not be_nil
      message.not_nil!.should contain("nope.key")
      message.not_nil!.should contain("RAILS_MASTER_KEY")
    end
  end

  it "raises InvalidMessage with a wrong key (cred_wrong_key_class)" do
    expect_raises(ActiveSupport::MessageEncryptor::InvalidMessage) do
      fixture_config(key_file: "wrong.key").read
    end
  end

  it "raises InvalidMessage with a short key (cred_short_key_class)" do
    expect_raises(ActiveSupport::MessageEncryptor::InvalidMessage) do
      fixture_config(key_file: "short.key").read
    end
  end

  it "ENV key wins over the key file (cred_env_key)" do
    ENV["RAILS_MASTER_KEY"] = KEY_HEX
    config = CRails::EncryptedConfiguration.new(
      content_path: File.join(FIXTURES, "credentials.yml.enc"),
      key_path: File.join(FIXTURES, "nope.key"))
    (config.read == YAML_CONTENT).to_s.should eq CRED_EXPECTED["cred_env_key"]
  ensure
    ENV.delete("RAILS_MASTER_KEY")
  end
end

describe "credentials write (reverse)" do
  it "writes a file the gem reads back" do
    out_path = File.join(FIXTURES, "port_written.yml.enc")
    config = CRails::EncryptedConfiguration.new(
      content_path: out_path, key_path: File.join(FIXTURES, "master.key"))
    config.write("port: written\nanswer: 42\n")

    # port reads its own file
    config.read.should eq "port: written\nanswer: 42\n"

    # the gem reads it (reverse verification)
    verify = "#{__DIR__}/../oracle/verify_credentials.rb"
    env = {"GEM_HOME" => ENV["GRAILS_GEM_HOME"]? || ENV["GEM_HOME"]? || "",
           "PATH" => ENV["PATH"]? || ""}
    status = Process.run(
      "ruby", [verify, out_path, File.join(FIXTURES, "master.key")],
      output: output = IO::Memory.new, error: STDERR, env: env)
    status.success?.should be_true
    lines = output.to_s.split("\n")
    lines.should contain("verify_readable\ttrue")
    lines.should contain("verify_content\t\"port: written\\nanswer: 42\\n\"")
  ensure
    File.delete(out_path) if out_path && File.exists?(out_path)
  end
end

describe "CRails.secret_key_base" do
  it "prefers ENV then app credentials" do
    # временный app-root с config/{master.key,credentials.yml.enc}
    app_root = File.join("/tmp", "crails_cred_spec_#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(File.join(app_root, "config"))
    File.write(File.join(app_root, "config", "master.key"), KEY_HEX + "\n")
    FileUtils.cp(File.join(FIXTURES, "credentials.yml.enc"),
                 File.join(app_root, "config", "credentials.yml.enc"))

    CRails.root = app_root
    ENV.delete("SECRET_KEY_BASE")
    CRails.secret_key_base.should eq "6a1c7f75a2b4f0e4d6c8e9f0a1b2c3d4"
    ENV["SECRET_KEY_BASE"] = "from-env"
    CRails.secret_key_base.should eq "from-env"
    ENV.delete("SECRET_KEY_BASE")
  ensure
    FileUtils.rm_rf(app_root) if app_root
  end
end


ENVC_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/credentials_env_expected.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
    end
  end
  hash
end

PROD_KEY_HEX = "e3b0c44298fc1c149afbf4c8996fb924"
PROD_ENC_FIXTURE = File.join(FIXTURES, "production.yml.enc")
PROD_KEY_FIXTURE = File.join(FIXTURES, "production.key")

# tmp-app c глобальными + env-производственными credentials (фикстуры
# сгенерированы реальным гему, см. oracle/credentials_env_cases.rb)
private def envc_app_root : String
  app_root = File.join("/tmp", "crails_envc_spec_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(File.join(app_root, "config", "credentials"))
  File.write(File.join(app_root, "config", "master.key"), KEY_HEX + "\n")
  FileUtils.cp(File.join(FIXTURES, "credentials.yml.enc"),
               File.join(app_root, "config", "credentials.yml.enc"))
  FileUtils.cp(PROD_ENC_FIXTURE,
               File.join(app_root, "config", "credentials", "production.yml.enc"))
  FileUtils.cp(PROD_KEY_FIXTURE,
               File.join(app_root, "config", "credentials", "production.key"))
  app_root
end

private def clean_cred_env : Nil
  ENV.delete("RAILS_MASTER_KEY")
  ENV.delete("CRAILS_MASTER_KEY")
  ENV.delete("SECRET_KEY_BASE")
  ENV.delete("SECRET_KEY_BASE_DUMMY")
end

describe "per-environment credentials (oracle envc_*)" do
  it "resolves env-specific paths when the env files exist (envc_paths)" do
    app_root = envc_app_root
    CRails.root = app_root
    content_path, key_path = CRails.credentials_paths("production")
    [File.basename(content_path), File.basename(key_path)].join(",").should eq ENVC_EXPECTED["envc_paths"]
  ensure
    FileUtils.rm_rf(app_root) if app_root
  end

  it "reads env credentials with the env key (envc_read, envc_skb)" do
    app_root = envc_app_root
    clean_cred_env
    CRails.root = app_root
    CRails.env = CRails::Env::Production
    CRails.credentials.dig("database", "password").try(&.as_s?).should eq ENVC_EXPECTED["envc_read"]
    CRails.credentials.secret_key_base.should eq ENVC_EXPECTED["envc_skb"]
    CRails.secret_key_base.should eq ENVC_EXPECTED["envc_app_skb"]
  ensure
    FileUtils.rm_rf(app_root) if app_root
  end

  it "ENV key decrypts the env file without key files (envc_envkey_read)" do
    app_root = envc_app_root
    clean_cred_env
    FileUtils.rm(File.join(app_root, "config", "credentials", "production.key"))
    ENV["RAILS_MASTER_KEY"] = PROD_KEY_HEX
    CRails.root = app_root
    CRails.env = CRails::Env::Production
    CRails.credentials.dig("database", "password").try(&.as_s?).should eq ENVC_EXPECTED["envc_envkey_read"]
  ensure
    ENV.delete("RAILS_MASTER_KEY")
    FileUtils.rm_rf(app_root) if app_root
  end

  it "falls back to global files when env files are absent (envc_fb_paths)" do
    app_root = envc_app_root
    clean_cred_env
    FileUtils.rm_rf(File.join(app_root, "config", "credentials"))
    content_path, key_path = CRails.credentials_paths("production")
    [File.basename(content_path), File.basename(key_path)].join(",").should eq ENVC_EXPECTED["envc_fb_paths"]
    CRails.root = app_root
    CRails.env = CRails::Env::Production
    CRails.credentials.read.empty?.to_s.should eq ENVC_EXPECTED["envc_fb_read_empty"]
    CRails.credentials.secret_key_base.should eq "6a1c7f75a2b4f0e4d6c8e9f0a1b2c3d4"
  ensure
    FileUtils.rm_rf(app_root) if app_root
  end

  it "soft mode: no key anywhere -> key? false, read empty, key_path fallback (envc_nokey_*)" do
    app_root = envc_app_root
    clean_cred_env
    FileUtils.rm(File.join(app_root, "config", "master.key"))
    FileUtils.rm(File.join(app_root, "config", "credentials", "production.key"))
    CRails.root = app_root
    CRails.env = CRails::Env::Production
    creds = CRails.credentials
    creds.key?.to_s.should eq ENVC_EXPECTED["envc_nokey_key"]
    creds.read.inspect.should eq ENVC_EXPECTED["envc_nokey_read"]
    creds.secret_key_base.nil?.to_s.should eq ENVC_EXPECTED["envc_nokey_skb_nil"]
    File.basename(creds.key_path).should eq ENVC_EXPECTED["envc_nokey_keypath"]
    # production без ключей -> secret_key_base nil (никакого local_secret)
    local = File.join(app_root, "tmp", "local_secret.txt")
    CRails.secret_key_base.should be_nil
    File.exists?(local).should be_false
  ensure
    FileUtils.rm_rf(app_root) if app_root
  end

  it "key present but no content file -> read empty, skb nil (envc_nofile_*)" do
    app_root = envc_app_root
    clean_cred_env
    FileUtils.rm(File.join(app_root, "config", "credentials", "production.yml.enc"))
    FileUtils.rm(File.join(app_root, "config", "credentials.yml.enc"))
    CRails.root = app_root
    CRails.env = CRails::Env::Production
    CRails.credentials.read.inspect.should eq ENVC_EXPECTED["envc_nofile_read"]
    CRails.credentials.secret_key_base.nil?.to_s.should eq ENVC_EXPECTED["envc_nofile_skb_nil"]
  ensure
    FileUtils.rm_rf(app_root) if app_root
  end

  it "SECRET_KEY_BASE wins over env credentials (envc_env_precedence)" do
    app_root = envc_app_root
    clean_cred_env
    ENV["SECRET_KEY_BASE"] = "from-env"
    CRails.root = app_root
    CRails.env = CRails::Env::Production
    CRails.secret_key_base.should eq ENVC_EXPECTED["envc_env_precedence"]
  ensure
    ENV.delete("SECRET_KEY_BASE")
    FileUtils.rm_rf(app_root) if app_root
  end

  after_all do
    CRails.env = CRails::Env::Development
  end
end

describe "tmp/local_secret.txt (Rails 8 generate_local_secret)" do
  it "generates a stable 128-char secret in development (envc_local_*)" do
    app_root = envc_app_root
    clean_cred_env
    FileUtils.rm_rf(File.join(app_root, "config")) # никаких credentials
    CRails.root = app_root
    CRails.env = CRails::Env::Development
    s1 = CRails.secret_key_base.not_nil!
    s2 = CRails.secret_key_base.not_nil!
    (s1 == s2).to_s.should eq ENVC_EXPECTED["envc_local_stable"]
    s1.size.to_s.should eq ENVC_EXPECTED["envc_local_len"]
    File.exists?(File.join(app_root, "tmp", "local_secret.txt")).to_s.should eq ENVC_EXPECTED["envc_local_file"]
    File.basename(CRails.credentials.content_path).should eq ENVC_EXPECTED["envc_local_paths"]
  ensure
    FileUtils.rm_rf(app_root) if app_root
  end

  it "SECRET_KEY_BASE_DUMMY forces the local secret in any env (envc_dummy_*)" do
    app_root = envc_app_root
    clean_cred_env
    ENV["SECRET_KEY_BASE_DUMMY"] = "1"
    CRails.root = app_root
    CRails.env = CRails::Env::Production
    s = CRails.secret_key_base.not_nil!
    File.exists?(File.join(app_root, "tmp", "local_secret.txt")).to_s.should eq ENVC_EXPECTED["envc_dummy_file"]
    s.size.to_s.should eq ENVC_EXPECTED["envc_dummy_len"]
    (s == File.read(File.join(app_root, "tmp", "local_secret.txt")).strip).to_s.should eq ENVC_EXPECTED["envc_dummy_matches"]
  ensure
    ENV.delete("SECRET_KEY_BASE_DUMMY")
    FileUtils.rm_rf(app_root) if app_root
  end

  after_all do
    CRails.env = CRails::Env::Development
  end
end

describe "credentials change (edit semantics)" do
  it "change writes through a tempfile and re-encrypts on modification" do
    out_path = File.join(FIXTURES, "port_changed.yml.enc")
    config = CRails::EncryptedConfiguration.new(
      content_path: out_path, key_path: File.join(FIXTURES, "master.key"))
    config.write("port: written\nanswer: 42\n")

    seen_in_editor = ""
    config.change do |tmp_path|
      File.basename(tmp_path).should contain("-port_changed.yml")
      seen_in_editor = File.read(tmp_path)
      File.write(tmp_path, seen_in_editor + "extra: true\n")
    end
    seen_in_editor.should eq "port: written\nanswer: 42\n"
    config.read.should eq "port: written\nanswer: 42\nextra: true\n"
    File.exists?("#{out_path}.tmp").should be_false

    # the gem reads the re-encrypted file back (reverse verification)
    verify = "#{__DIR__}/../oracle/verify_credentials.rb"
    env = {"GEM_HOME" => ENV["GRAILS_GEM_HOME"]? || ENV["GEM_HOME"]? || "",
           "PATH" => ENV["PATH"]? || ""}
    status = Process.run(
      "ruby", [verify, out_path, File.join(FIXTURES, "master.key")],
      output: output = IO::Memory.new, error: STDERR, env: env)
    status.success?.should be_true
    output.to_s.split("\n").should contain("verify_content\t\"port: written\\nanswer: 42\\nextra: true\\n\"")
  ensure
    File.delete(out_path) if out_path && File.exists?(out_path)
  end

  it "change without modification leaves the file untouched" do
    out_path = File.join(FIXTURES, "port_unchanged.yml.enc")
    config = CRails::EncryptedConfiguration.new(
      content_path: out_path, key_path: File.join(FIXTURES, "master.key"))
    config.write("stable: yes\n")
    before = File.info(out_path).modification_time
    config.change { |tmp_path| File.read(tmp_path).should eq "stable: yes\n" }
    File.info(out_path).modification_time.should eq before
  ensure
    File.delete(out_path) if out_path && File.exists?(out_path)
  end
end
