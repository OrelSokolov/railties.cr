# Mirror of oracle/integration_expected.yml (captured from rails 8.1.4
# via oracle/integration_cases.rb — a minimal inline app driven through
# ActionDispatch::Integration::Session). Same case IDs, same
# expectations, no edits on either side. Exercises the CRails port of
# Rails' integration testing (src/testing/integration.cr): in-process
# requests through the full middleware chain, cookie-jar continuity
# (session / flash / signed cookies), redirect handling, method
# tunneling and response assertions.

require "spec"
require "../src/railties_cr"

INTEGRATION_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/integration_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

# --- controllers (mirroring the oracle's controller 1:1) ---------------

class OracleController < ActionController::Base
  def show
    render plain: "show ok"
  end

  def echo
    render plain: params.keys.sort.map { |k| "#{k}=#{params[k]}" }.join("&")
  end

  def echo_post
    render plain: "title=#{params.dig("post", "title")}"
  end

  def bump
    session["count"] = (session["count"]? || "0").to_i.succ.to_s
    render plain: "count=#{session["count"]}"
  end

  def bounce
    redirect_to "/flash_show", notice: "Saved"
  end

  def flash_show
    render plain: (flash["notice"]? || "").to_s
  end

  def redirect_me
    redirect_to "/target"
  end

  def redirect_twice
    redirect_to "/redirect_me"
  end

  def target
    render plain: "target reached"
  end

  def set_cookie
    cookies["token"] = "abc"
    render plain: "set"
  end

  def read_cookie
    render plain: "token=#{cookies["token"]?}"
  end

  def set_signed
    cookies.signed["who"] = "me"
    render plain: "set"
  end

  def read_signed
    render plain: "who=#{cookies.signed["who"]?}"
  end

  def echo_json
    render json: %({"name":"#{params["name"]}"})
  end

  def update
    render plain: "PATCH done"
  end

  def headers_echo
    render plain: request.headers["X-Test-Header"].to_s
  end

  def remove
    render plain: "removed #{params["id"]}"
  end
end

APP_INTEGRATION = CRails::Application.new.tap do |app|
  app.routes.draw do
    get  "/show",          to: "oracle#show"
    get  "/echo",          to: "oracle#echo"
    post "/echo_post",     to: "oracle#echo_post"
    get  "/bump",          to: "oracle#bump"
    get  "/bounce",        to: "oracle#bounce"
    get  "/flash_show",    to: "oracle#flash_show"
    get  "/redirect_me",   to: "oracle#redirect_me"
    get  "/redirect_twice", to: "oracle#redirect_twice"
    get  "/target",        to: "oracle#target"
    get  "/set_cookie",    to: "oracle#set_cookie"
    get  "/read_cookie",   to: "oracle#read_cookie"
    get  "/set_signed",    to: "oracle#set_signed"
    get  "/read_signed",   to: "oracle#read_signed"
    post "/echo_json",     to: "oracle#echo_json"
    patch "/update",       to: "oracle#update"
    get  "/headers_echo",  to: "oracle#headers_echo"
    delete "/remove",      to: "oracle#remove"
  end
end

ActionController.cookies_secret_key_base = "a" * 64 # transcript-stable dummy

module SpecRun
  class_property session : ActionDispatch::IntegrationSession?
end

def run
  SpecRun.session ||= ActionDispatch::IntegrationSession.new(APP_INTEGRATION)
end

describe "integration session (rails 8.1.4 oracle)" do
  it "get_show" do
    run.get "/show"
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["get_show"]
  end

  it "get_with_params" do
    run.get "/echo", params: {"b" => "2", "a" => "1"}
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["get_with_params"]
  end

  it "post_form_nested" do
    run.post "/echo_post", params: {"post" => {"title" => "T1"}}
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["post_form_nested"]
  end

  it "session_counter_twice" do
    run.get "/bump"
    first = run.response.not_nil!.body
    run.get "/bump"
    "#{run.response.not_nil!.status_code}|#{first}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["session_counter_twice"]
  end

  it "flash_across_redirect" do
    run.get "/bounce"
    resp = run.response.not_nil!
    first = "#{resp.status_code}|#{run.path}|#{resp.body}"
    run.get "/flash_show"
    resp = run.response.not_nil!
    "#{first}||#{resp.status_code}|#{run.path}|#{resp.body}"
      .should eq INTEGRATION_EXPECTED["flash_across_redirect"]
  end

  it "redirect_followed" do
    run.get "/redirect_me"
    resp = run.response.not_nil!
    first = "#{resp.status_code}|#{run.path}|#{resp.body}"
    run.follow_redirect!
    resp = run.response.not_nil!
    "#{first}||#{resp.status_code}|#{run.path}|#{resp.body}"
      .should eq INTEGRATION_EXPECTED["redirect_followed"]
  end

  it "redirect_chain" do
    run.get "/redirect_twice"
    resp = run.response.not_nil!
    first = "#{resp.status_code}|#{run.path}|#{resp.body}"
    run.follow_redirect!
    resp = run.response.not_nil!
    second = "#{resp.status_code}|#{run.path}|#{resp.body}"
    run.follow_redirect!
    resp = run.response.not_nil!
    "#{first}||#{second}||#{resp.status_code}|#{run.path}|#{resp.body}"
      .should eq INTEGRATION_EXPECTED["redirect_chain"]
  end

  it "cookie_roundtrip" do
    run.get "/set_cookie"
    run.get "/read_cookie"
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["cookie_roundtrip"]
  end

  it "signed_cookie_roundtrip" do
    run.get "/set_signed"
    run.get "/read_signed"
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["signed_cookie_roundtrip"]
  end

  it "json_post_echo" do
    run.post "/echo_json", json: %({"name":"crails"})
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["json_post_echo"]
  end

  it "not_found" do
    run.get "/nope"
    run.response.not_nil!.status_code.to_s.should eq INTEGRATION_EXPECTED["not_found"]
    run.assert_response(:missing)
  end

  it "method_override_patch" do
    run.post "/update", params: {"_method" => "patch"}
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["method_override_patch"]
  end

  it "head_request" do
    run.head "/show"
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["head_request"]
  end

  it "header_echo" do
    run.get "/headers_echo", headers: {"X-Test-Header" => "abc"}
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["header_echo"]
  end

  it "delete_with_query" do
    run.delete "/remove", params: {"id" => "7"}
    "#{run.response.not_nil!.status_code}|#{run.response.not_nil!.body}"
      .should eq INTEGRATION_EXPECTED["delete_with_query"]
  end
end
