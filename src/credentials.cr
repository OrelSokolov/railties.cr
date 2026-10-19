# CRails::EncryptedConfiguration — порт ActiveSupport::EncryptedFile +
# Rails::Application::Credentials (фаза B).
#
# Wire (оракул oracle/credentials_cases.rb → oracle/credentials_expected.yml,
# снят с activesupport 8.1.4):
#   * cipher aes-128-gcm (EncryptedFile::CIPHER), ключ = hex(master.key)
#     → байты (ruby pack("H*"));
#   * конверт: legacy 3 части strict-base64 iv--ciphertext--auth_tag
#     (serializer Marshal, без purpose → без _rails/JSON-конверта);
#   * plaintext внутри = Marshal.dump(String) YAML-документа
#     (MarshalStringCodec ниже: единственный нужный срез Marshal —
#     UTF-8 строки; длины: n<=122 → байт n+5, иначе 1..4 + LE-байты);
#   * ключ: ENV RAILS_MASTER_KEY/CRAILS_MASTER_KEY → файл master.key →
#     MissingKeyError; неверный/короткий ключ → InvalidMessage.
#
# Совпадает с гемом: env-резолв config/credentials/#{env}.* с fallback
# на глобальные credentials.yml.enc/master.key (без merge — env-файл
# полностью заменяет глобальный); атомарная запись (.tmp + rename);
# edit-фаза change (tmp-файл → редактор → перешифровка при изменении);
# tmp/local_secret.txt для dev/test secret_key_base.
# Отклонение от гема: YAML-доступ через YAML::Any (dig/[]/fetch).

require "base64"
require "yaml"
require "random/secure"
require "active_support_cr"

module CRails
  # Marshal-фрейминг одной UTF-8 строки (ruby Marshal.dump/load String).
  module MarshalStringCodec
    HEADER      = Bytes[0x04, 0x08]
    IVAR_STRING = Bytes[0x49, 0x22] # I"
    IVAR_TRAILER = Bytes[0x06, 0x3a, 0x06, 0x45, 0x54] # \x06:\x06ET

    def self.dump(s : String) : String
      bytes = s.to_slice
      String.build do |io|
        io.write(HEADER)
        io.write(IVAR_STRING)
        write_long(io, bytes.size)
        io.write(bytes)
        io.write(IVAR_TRAILER)
      end
    end

    def self.load(raw : String) : String?
      bytes = raw.to_slice
      pos = 0
      return nil unless bytes.size > 4 && bytes[0, 2] == HEADER
      pos += 2
      # опциональный I-флаг (ruby < 3.4 ASCII-строки без ivar)
      if bytes[pos]? == 0x49
        pos += 1
        return nil unless bytes[pos]? == 0x22
      else
        return nil unless bytes[pos]? == 0x22
      end
      pos += 1
      len, pos = read_long(bytes, pos)
      return nil if len.nil? || pos + len > bytes.size
      content = bytes[pos, len]
      String.new(content)
    end

    private def self.write_long(io : IO, n : Int32) : Nil
      if n <= 122
        io.write_byte((n + 5).to_u8)
      else
        magnitude = n
        stack = [] of UInt8
        while magnitude > 0
          stack << (magnitude & 0xFF).to_u8
          magnitude >>= 8
        end
        io.write_byte(stack.size.to_u8)
        stack.each { |b| io.write_byte(b) }
      end
    end

    private def self.read_long(bytes : Bytes, pos : Int32) : {Int32?, Int32}
      b = bytes[pos]?
      return {nil, pos} unless b
      if b >= 5 && b <= 127
        {(b - 5).to_i32, pos + 1}
      elsif b >= 1 && b <= 4
        value = 0
        b.times do |i|
          byte = bytes[pos + 1 + i]?
          return {nil, pos} unless byte
          value |= byte.to_i32 << (8 * i)
        end
        {value, pos + 1 + b}
      else
        {nil, pos}
      end
    end
  end

  class EncryptedConfiguration
    class MissingContentError < Exception
      def initialize(content_path : String)
        super("Missing encrypted content file in #{content_path}.")
      end
    end

    class MissingKeyError < Exception
      def initialize(key_path : String, env_key : String)
        super("Missing encryption key to decrypt file with. Ask your " \
              "team for your master key and write it to #{key_path} or " \
              "put it in the ENV['#{env_key}'].")
      end
    end

    DEFAULT_ENV_KEY = "RAILS_MASTER_KEY"

    attr_reader content_path : String
    attr_reader key_path : String
    attr_reader env_key : String

    def initialize(@content_path : String, @key_path : String,
                   @env_key : String = DEFAULT_ENV_KEY,
                   @raise_if_missing_key : Bool = true)
    end

    # Ключ: ENV → key-файл; nil при отсутствии в soft-режиме
    # (raise_if_missing_key = false — так Rails создаёт app-credentials,
    # require_master_key по умолчанию выключен), MissingKeyError в strict.
    def key : Bytes?
      read_env_key || read_key_file || handle_missing_key
    end

    def key? : Bytes?
      read_env_key || read_key_file
    end

    # Расшифрованный YAML-документ (memo; сбрасывается write-ом).
    # Пустой контент (файла нет / soft-режим без ключа) → пустой конфиг.
    def config : YAML::Any
      @config ||= begin
        content = read
        content.blank? ? YAML.parse("{}") : YAML.parse(content)
      end
    end

    # Расшифрованный контент. Strict-режим: MissingKeyError без ключа
    # (как EncryptedFile#read → key). Soft-режим (app-credentials):
    # MissingContentError глотается → "" — Rails позволяет стартовать
    # приложение без credentials-файла/ключа.
    def read : String
      k = key
      raise MissingContentError.new(@content_path) unless k && File.exists?(@content_path)
      wire = File.read(@content_path)
      raw = encryptor.decrypt_and_verify(wire)
      raw_str = raw.as?(String) ||
        raise(ActiveSupport::MessageEncryptor::InvalidMessage.new("bad marshal frame"))
      MarshalStringCodec.load(raw_str) ||
        raise(ActiveSupport::MessageEncryptor::InvalidMessage.new("bad marshal frame"))
    rescue ex : MissingContentError
      raise ex if @raise_if_missing_key
      ""
    end

    # Атомарная запись (гем: .tmp + FileUtils.mv).
    def write(content : String) : Nil
      raise MissingKeyError.new(@key_path, @env_key) unless key?
      tmp = "#{@content_path}.tmp"
      File.write(tmp, encryptor.encrypt_and_sign(MarshalStringCodec.dump(content)))
      File.rename(tmp, @content_path)
      @config = nil
    end

    # Edit-фаза (EncryptedFile#change): расшифровать во временный файл,
    # отдать блоку (редактору), перешифровать при изменении.
    def change(& : String ->) : Nil
      writing(read) { |tmp_path| yield tmp_path }
    end

    # --- YAML-доступ ---------------------------------------------------

    def [](key : String) : YAML::Any
      fetch(key) { raise KeyError.new("key not found: \"#{key}\"") }
    end

    def []?(key : String) : YAML::Any?
      value = config[key]?
      nil_value?(value) ? nil : value
    end

    def dig(*keys : String) : YAML::Any?
      value = config.dig(*keys)
      nil_value?(value) ? nil : value
    end

    def fetch(key : String, default = nil) : YAML::Any?
      value = config[key]?
      return default if nil_value?(value)
      value
    end

    def fetch(key : String, &) : YAML::Any?
      value = config[key]?
      return yield(key) if nil_value?(value)
      value
    end

    def secret_key_base : String?
      self["secret_key_base"]?.try(&.as_s?)
    end

    # --- ключ -----------------------------------------------------------

    private def read_env_key : Bytes?
      hex = ENV[@env_key]? || ENV["CRAILS_MASTER_KEY"]?
      hex ? hex_to_bytes(hex.strip) : nil
    end

    private def read_key_file : Bytes?
      return nil unless File.exists?(@key_path)
      hex_to_bytes(File.read(@key_path).strip)
    end

    private def handle_missing_key : Bytes?
      raise MissingKeyError.new(@key_path, @env_key) if @raise_if_missing_key
      nil
    end

    private def hex_to_bytes(hex : String) : Bytes
      # ruby pack("H*"): непарный последний nibble добивается нулём
      bytes = Bytes.new((hex.size + 1) // 2)
      hex.each_char_with_index do |c, i|
        v = c.to_i?(16) || 0
        if i.even?
          bytes[i // 2] |= (v << 4).to_u8
        else
          bytes[i // 2] |= v.to_u8
        end
      end
      bytes
    end

    @encryptor : ActiveSupport::MessageEncryptor?

    private def encryptor : ActiveSupport::MessageEncryptor
      @encryptor ||= ActiveSupport::MessageEncryptor.new(key.not_nil!,
        cipher: "aes-128-gcm", serializer: :null)
    end

    private def writing(contents : String, &) : Nil
      suffix = "-" + File.basename(@content_path).chomp(".enc")
      File.tempfile("", suffix) do |tmp|
        File.write(tmp.path, contents)
        yield tmp.path
        updated = File.read(tmp.path)
        write(updated) if updated != contents
      end
    end

    private def nil_value?(value) : Bool
      # YAML.parse отдаёт "" для пустого документа; ключи без значения — nil
      value.nil? || (value.as_s? == "")
    end
  end

  # Резолв путей credentials для env (credentials_defaults гема):
  # config/credentials/#{env}.yml.enc существует → он, иначе глобальный
  # config/credentials.yml.enc; ключ аналогично (#{env}.key → master.key).
  # Merge нет: env-файл полностью заменяет глобальный.
  def self.credentials_paths(env : String) : {String, String}
    root = CRails.root
    content_path = File.join(root, "config", "credentials", "#{env}.yml.enc")
    content_path = File.join(root, "config", "credentials.yml.enc") unless File.exists?(content_path)
    key_path = File.join(root, "config", "credentials", "#{env}.key")
    key_path = File.join(root, "config", "master.key") unless File.exists?(key_path)
    {content_path, key_path}
  end

  # config/credentials приложения (lazy; env-резолв от CRails.env;
  # raise_if_missing_key = false — Rails default, require_master_key).
  def self.credentials : EncryptedConfiguration
    @@credentials ||= begin
      content_path, key_path = credentials_paths(env.to_s.downcase)
      EncryptedConfiguration.new(content_path, key_path,
        raise_if_missing_key: false)
    end
  end

  # Принудительные env-пути без fallback (credentials:edit
  # --environment ENV: создаёт config/credentials/#{env}.{yml.enc,key}).
  def self.env_credentials(env : String) : EncryptedConfiguration
    EncryptedConfiguration.new(
      content_path: File.join(CRails.root, "config", "credentials", "#{env}.yml.enc"),
      key_path: File.join(CRails.root, "config", "credentials", "#{env}.key"),
      raise_if_missing_key: false)
  end

  # Rails 8 generate_local_secret: tmp/local_secret.txt — генерится раз
  # и переиспользуется (hex(64), 128 символов).
  def self.generate_local_secret : String
    key_file = File.join(CRails.root, "tmp", "local_secret.txt")
    unless File.exists?(key_file)
      random_key = Random::Secure.hex(64)
      Dir.mkdir_p(File.join(CRails.root, "tmp"))
      File.write(key_file, random_key)
    end
    File.read(key_file).strip
  end

  # Rails.secret_key_base: SECRET_KEY_BASE_DUMMY → local_secret; иначе
  # ENV → credentials.secret_key_base → local_secret в dev/test.
  def self.secret_key_base : String?
    return generate_local_secret if ENV["SECRET_KEY_BASE_DUMMY"]?
    ENV["SECRET_KEY_BASE"]? ||
      (credentials.secret_key_base ||
        (CRails.env.local? ? generate_local_secret : nil))
  rescue ex : CRails::EncryptedConfiguration::MissingKeyError
    nil
  rescue ex : ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  rescue ex : File::NotFoundError
    nil
  end

  # Выставить secret_key_base для подписи cookies/session (soft —
  # конфиг action_pack может отсутствовать в не-веб рантаймах).
  def self.apply_secret_key_base! : Nil
    secret = CRails.secret_key_base
    return unless secret
    {% if ::ActionController.resolve? %}
      ActionController.cookies_secret_key_base = secret
    {% end %}
  end
end
