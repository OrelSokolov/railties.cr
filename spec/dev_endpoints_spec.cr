# Dev endpoints (CRails.dev_endpoints): the mounting point for
# framework-shard dev UIs — action_mailer_cr's /rails/mailers previews.
# Served by the Dispatcher instead of routing when config.show_previews
# is on (development default) and the app has no route of its own.

require "spec"
require "../src/railties_cr"

DEV_APP = CRails::Application.new
DEV_APP.config.show_previews = true

CRails.dev_endpoints["/rails/mailers"] = ->(context : HTTP::Server::Context) {
  context.response.status_code = 200
  context.response.headers["Content-Type"] = "text/html; charset=utf-8"
  context.response.print "MAILER PREVIEWS INDEX"
  true
}

dev_server = HTTP::Server.new do |context|
  DEV_APP.call(context)
end

module DevEnv
  class_property addr : Socket::IPAddress?
end

DevEnv.addr = dev_server.bind_tcp("127.0.0.1", 0)
DEV_ADDR = DevEnv.addr.not_nil!
spawn { dev_server.listen }
sleep 50.milliseconds

def dev_request(method : String, path : String) : HTTP::Client::Response
  addr = DEV_ADDR
  HTTP::Client.new(addr.address, addr.port) do |client|
    client.exec(method, path)
  end
end

describe "CRails.dev_endpoints (/rails/mailers mounting)" do
  it "serves a registered prefix when show_previews is on" do
    response = dev_request("GET", "/rails/mailers")
    response.status_code.should eq(200)
    response.body.should contain("MAILER PREVIEWS INDEX")
  end

  it "matches the prefix with subpaths" do
    response = dev_request("GET", "/rails/mailers/user_mailer/welcome")
    response.status_code.should eq(200)
  end

  it "does not shadow app routes" do
    DEV_APP.routes.draw do
      get "/rails/mailers", to: "dummy#show"
    end
    # No Dummy controller is compiled in — the app route wins over the
    # dev endpoint and dispatch raises RoutingError → 404.
    response = dev_request("GET", "/rails/mailers")
    response.status_code.should eq(404)
    response.body.should_not contain("MAILER PREVIEWS INDEX")
  end

  it "404s unregistered paths (no endpoint)" do
    response = dev_request("GET", "/rails/other")
    response.status_code.should eq(404)
  end

  it "skips dev endpoints when show_previews is off" do
    DEV_APP.config.show_previews = false
    begin
      response = dev_request("GET", "/rails/mailers/user_mailer/welcome")
      response.status_code.should eq(404)
    ensure
      DEV_APP.config.show_previews = true
    end
  end
end
