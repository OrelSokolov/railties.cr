# Rails.application.key_generator / message_verifier (railties 8.1.4
# application.rb): PBKDF2-вывод один раз на процесс — повторные вызовы
# возвращают тот же объект, верификатор подтверждает свой же токен.

require "spec"
require "../src/railties_cr"

describe "CRails::Application key verifiers" do
  it "memoizes key_generator per secret" do
    ENV["SECRET_KEY_BASE"] = "spec-secret-1"
    app = CRails::Application.new
    key_generator = app.key_generator
    app.key_generator.should be(key_generator)
    # Тот же секрет у нового приложения — тот же производный ключ.
    CRails::Application.new.key_generator
      .generate_key("active_record/signed_id")
      .should eq(key_generator.generate_key("active_record/signed_id"))
  end

  it "memoizes message_verifier by (secret, salt, digest, url_safe)" do
    ENV["SECRET_KEY_BASE"] = "spec-secret-1"
    app = CRails::Application.new
    verifier = app.message_verifier("active_record/signed_id", url_safe: true)
    app.message_verifier("active_record/signed_id", url_safe: true)
      .should be(verifier)
    # Другой digest — другой инстанс.
    app.message_verifier("active_record/signed_id", digest: :sha1, url_safe: true)
      .should_not be(verifier)
  end

  it "round-trips a signed token through the memoized verifier" do
    ENV["SECRET_KEY_BASE"] = "spec-secret-1"
    verifier = CRails::Application.new
      .message_verifier("user/avatar", url_safe: true)
    token = verifier.generate(149087659, purpose: "user/avatar")
    verifier.verified_any(token, purpose: "user/avatar")
      .try(&.as_i?).should eq(149087659)
  end

  it "re-derives the key when secret_key_base changes" do
    ENV["SECRET_KEY_BASE"] = "spec-secret-1"
    app = CRails::Application.new
    first = app.message_verifier("user/avatar", url_safe: true)
    ENV["SECRET_KEY_BASE"] = "spec-secret-2"
    app.message_verifier("user/avatar", url_safe: true).should_not be(first)
    ENV["SECRET_KEY_BASE"] = "spec-secret-1"
  end
end
