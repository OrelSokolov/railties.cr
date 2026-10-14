# E2E (Iteration 10): typed params through the full CRails stack —
# invalid JSON body → 422 with the error tree as JSON (the railties
# rescue ladder), valid body → typed access in the action; and the
# OpenAPI document endpoint mounted via the routes drawer.

require "spec"
require "json"
require "../src/railties_cr"

class TpApiController < ActionController::Base
  typed_params(:create) do
    required :title, String, min_size: 3
    required :count, Int32, gteq: 1
    optional :admin, Bool?
  end

  def create
    fp = create_params
    render json: {"title" => fp.title, "count" => fp.count, "admin" => fp.admin}.to_json
  end
end

APP_TP = CRails::Application.new.tap do |app|
  app.routes.draw do
    post "/api/things", to: "tp_api#create"
    openapi "/openapi.json"
  end
  app.initialize!
end

module SpecTP
  class_property addr : Socket::IPAddress?
end

server = HTTP::Server.new { |ctx| APP_TP.call(ctx) }
SpecTP.addr = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }
sleep 50.milliseconds

def tp_req(method : String, path : String, body : String? = nil) : HTTP::Client::Response
  addr = SpecTP.addr.not_nil!
  headers = HTTP::Headers.new
  headers["Content-Type"] = "application/json" if body
  HTTP::Client.new(addr.address, addr.port) do |client|
    client.exec(HTTP::Request.new(method, path, headers: headers, body: body))
  end
end

describe "typed params E2E" do
  it "valid JSON body reaches typed getters" do
    res = tp_req("POST", "/api/things", %({"title": "Hello", "count": "5", "admin": "yes"}))
    res.status_code.should eq(200)
    body = JSON.parse(res.body)
    body["title"].should eq("Hello")
    body["count"].should eq(5)
    body["admin"].should eq(true)
  end

  it "invalid body maps to 422 with the error tree" do
    res = tp_req("POST", "/api/things", %({"title": "x", "count": "0"}))
    res.status_code.should eq(422)
    res.headers["Content-Type"].should contain("application/json")
    errors = JSON.parse(res.body)["errors"]
    errors["title"].as_a.map(&.as_s).should eq(["size cannot be less than 3"])
    errors["count"].as_a.map(&.as_s).should eq(["must be greater than or equal to 1"])
  end

  it "missing fields map to 422" do
    res = tp_req("POST", "/api/things", %({}))
    res.status_code.should eq(422)
    errors = JSON.parse(res.body)["errors"]
    errors["title"].as_a.map(&.as_s).should eq(["is missing"])
    errors["count"].as_a.map(&.as_s).should eq(["is missing"])
  end

  it "serves /openapi.json with the typed schema" do
    res = tp_req("GET", "/openapi.json")
    res.status_code.should eq(200)
    doc = JSON.parse(res.body)
    doc["openapi"].should eq("3.0.3")
    schema = doc["paths"]["/api/things"]["post"]["requestBody"]["content"]["application/json"]["schema"]
    schema["required"].as_a.map(&.as_s).sort.should eq(["count", "title"])
    schema["properties"]["title"]["minLength"].should eq(3)
    schema["properties"]["count"]["minimum"].should eq(1)
  end
end
