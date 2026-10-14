# Oracle cases for ActionDispatch::Integration / IntegrationTest:
# captured from Rails 8.1.4 (actionpack) through a minimal inline app —
# no `rails new` needed, the gem is booted directly. Self-contained:
#
#   ruby oracle/integration_cases.rb > oracle/integration_expected.yml
#
# Each line: "<case_id>\t<value>" (\n, \t, \r escaped in values).
# Mirrored 1:1 in spec/integration_spec.cr against the CRails port
# (src/testing/integration.cr) with byte-identical expectations.
#
# Transcript records only wire-stable facts: status codes, exact bodies
# of render plain:/json actions, redirect destinations and cookie
# round-trip results (signed/encrypted values themselves are
# secret-dependent and never recorded).

ENV["RAILS_ENV"] = "test"

require "rails"
require "action_controller/railtie"

abort "need rails 8.1.4, got #{Rails::VERSION::STRING}" unless Rails::VERSION::STRING == "8.1.4"

module OracleApp
  class Application < Rails::Application
    config.secret_key_base = "a" * 128 # transcript-stable dummy
    config.logger = Logger.new(IO::NULL)
    config.eager_load = false
    config.cache_store = :memory_store
    config.hosts.clear
  end
end

class OracleController < ActionController::Base
  def show
    render plain: "show ok"
  end

  def echo
    keys = params.to_unsafe_h.except("controller", "action").keys.sort
    render plain: keys.map { |k| "#{k}=#{params.to_unsafe_h[k]}" }.join("&")
  end

  def echo_post
    render plain: "title=#{params.dig(:post, :title)}"
  end

  def bump
    session[:count] = session[:count].to_i + 1
    render plain: "count=#{session[:count]}"
  end

  def bounce
    redirect_to "/flash_show", notice: "Saved"
  end

  def flash_show
    render plain: (flash[:notice] || "")
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
    cookies[:token] = {value: "abc", expires: 1.hour}
    render plain: "set"
  end

  def read_cookie
    render plain: "token=#{cookies[:token]}"
  end

  def set_signed
    cookies.signed[:who] = {value: "me"}
    render plain: "set"
  end

  def read_signed
    render plain: "who=#{cookies.signed[:who]}"
  end

  def echo_json
    render json: {name: params[:name]}
  end

  def update
    render plain: "PATCH done"
  end

  def headers_echo
    render plain: request.headers["X-Test-Header"].to_s
  end

  def remove
    render plain: "removed #{params[:id]}"
  end
end

OracleApp::Application.initialize!

OracleApp::Application.routes.draw do
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


def escape(value)
  value.to_s.gsub("\\", "\\\\\\\\").gsub("\n", "\\n").gsub("\t", "\\t").gsub("\r", "\\r")
end

def case_run(id)
  puts "#{id}\t#{escape(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class}"
end

def run
  @run ||= ActionDispatch::Integration::Session.new(OracleApp::Application)
end

# --- transcript ---------------------------------------------------------

case_run("get_show") do
  run.get "/show"
  "#{run.response.status}|#{run.response.body}"
end

case_run("get_with_params") do
  run.get "/echo", params: {b: "2", a: "1"}
  "#{run.response.status}|#{run.response.body}"
end

case_run("post_form_nested") do
  run.post "/echo_post", params: {"post" => {"title" => "T1"}}
  "#{run.response.status}|#{run.response.body}"
end

case_run("session_counter_twice") do
  run.get "/bump"
  first = run.response.body
  run.get "/bump"
  "#{run.response.status}|#{first}|#{run.response.body}"
end

case_run("flash_across_redirect") do
  run.get "/bounce"
  first = "#{run.response.status}|#{run.path}|#{run.response.body}"
  run.get "/flash_show"
  "#{first}||#{run.response.status}|#{run.path}|#{run.response.body}"
end

case_run("redirect_followed") do
  run.get "/redirect_me"
  first = "#{run.response.status}|#{run.path}|#{run.response.body}"
  run.follow_redirect!
  "#{first}||#{run.response.status}|#{run.path}|#{run.response.body}"
end

case_run("redirect_chain") do
  run.get "/redirect_twice"
  first = "#{run.response.status}|#{run.path}|#{run.response.body}"
  run.follow_redirect!
  second = "#{run.response.status}|#{run.path}|#{run.response.body}"
  run.follow_redirect!
  "#{first}||#{second}||#{run.response.status}|#{run.path}|#{run.response.body}"
end

case_run("cookie_roundtrip") do
  run.get "/set_cookie"
  run.get "/read_cookie"
  "#{run.response.status}|#{run.response.body}"
end

case_run("signed_cookie_roundtrip") do
  run.get "/set_signed"
  run.get "/read_signed"
  "#{run.response.status}|#{run.response.body}"
end

case_run("json_post_echo") do
  run.post "/echo_json", params: {name: "crails"}.to_json,
                         headers: {"Content-Type" => "application/json"}
  "#{run.response.status}|#{run.response.body}"
end

case_run("not_found") do
  run.get "/nope"
  run.response.status.to_s
end

case_run("method_override_patch") do
  run.post "/update", params: {_method: "patch"}
  "#{run.response.status}|#{run.response.body}"
end

case_run("head_request") do
  run.head "/show"
  "#{run.response.status}|#{run.response.body}"
end

case_run("header_echo") do
  run.get "/headers_echo", headers: {"X-Test-Header" => "abc"}
  "#{run.response.status}|#{run.response.body}"
end

case_run("delete_with_query") do
  run.delete "/remove", params: {id: "7"}
  "#{run.response.status}|#{run.response.body}"
end
