# Mirror of oracle/static_expected.yml (captured from actionpack 8.1.4
# ActionDispatch::Static via oracle/static_cases.rb). Same case IDs,
# same expectations. Runs the handler through a real HTTP server with a
# 404-fallback terminal handler, so pass-through is observable.
#
# The value format mirrors the oracle: "status|ct|cc|ce|vary|body".

require "spec"
require "../src/railties_cr"
require "file_utils"

STATIC_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/static_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp.gsub("\\n", "\n")
  end
  hash
end

ROOT = File.join(Dir.tempdir, "crails_static_spec_#{Random::Secure.hex(4)}")
FileUtils.mkdir_p(File.join(ROOT, "vite/assets"))
FileUtils.mkdir_p(File.join(ROOT, "docs"))
File.write(File.join(ROOT, "vite/assets/application-def456.js"), "console.log(1)\n")
File.write(File.join(ROOT, "vite/assets/application-def456.js.br"), "br-data")
File.write(File.join(ROOT, "vite/assets/application-def456.js.gz"), "gz-data")
File.write(File.join(ROOT, "vite/assets/app-def456.css"), "body{}\n")
File.write(File.join(ROOT, "vite/assets/logo-789.png"), "png")
File.write(File.join(ROOT, "docs/index.html"), "<h1>docs</h1>")

# Fallback "app": 404, like the oracle's FALLBACK lambda.
class StaticFallback
  include HTTP::Handler

  def call(context : HTTP::Server::Context) : Nil
    context.response.status_code = 404
    context.response.headers["Content-Type"] = "text/plain"
    context.response.print "404-fallback"
  end
end

# Bare handler (no extra headers), vite_immutable off — like the
# oracle's PLAIN Static instance.
plain = CRails::Middleware::Static.new(ROOT, {} of String => String, vite_immutable: false)
immutable = CRails::Middleware::Static.new(
  ROOT,
  {"Cache-Control" => "public, max-age=31536000, immutable"},
  vite_immutable: false)

module SpecStatic
  class_property addr : Socket::IPAddress?
  class_property imm_addr : Socket::IPAddress?
end

static_server = HTTP::Server.new([plain, StaticFallback.new] of HTTP::Handler)
SpecStatic.addr = static_server.bind_tcp("127.0.0.1", 0)
spawn { static_server.listen }

immutable_server = HTTP::Server.new([immutable, StaticFallback.new] of HTTP::Handler)
SpecStatic.imm_addr = immutable_server.bind_tcp("127.0.0.1", 0)
spawn { immutable_server.listen }
sleep 50.milliseconds

def static_call(addr, method : String, path : String,
                headers : Hash(String, String) = {} of String => String) : String
  h = HTTP::Headers.new
  headers.each { |k, v| h[k] = v }
  response = HTTP::Client.new(addr.address, addr.port) do |client|
    # Не подставлять свой Accept-Encoding — переговоры кодировок
    # управляются кейсом, как в Rack::MockRequest-оракуле.
    client.compress = false
    client.exec(HTTP::Request.new(method, path, headers: h))
  end
  hs = response.headers
  [response.status_code,
   hs["Content-Type"]? || "",
   hs["Cache-Control"]? || "",
   hs["Content-Encoding"]? || "",
   hs["Vary"]? || "",
   response.body? || ""].join("|")
end

describe "static files (actionpack 8.1.4 oracle)" do
  it "js_200" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/vite/assets/application-def456.js")
      .should eq STATIC_EXPECTED["js_200"]
  end

  it "css_200" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/vite/assets/app-def456.css")
      .should eq STATIC_EXPECTED["css_200"]
  end

  it "png_200" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/vite/assets/logo-789.png")
      .should eq STATIC_EXPECTED["png_200"]
  end

  it "index_html" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/docs/")
      .should eq STATIC_EXPECTED["index_html"]
  end

  it "dot_html" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/docs")
      .should eq STATIC_EXPECTED["dot_html"]
  end

  it "immutable_cache_control" do
    addr = SpecStatic.imm_addr.not_nil!
    static_call(addr, "GET", "/vite/assets/application-def456.js")
      .should eq STATIC_EXPECTED["immutable_cache_control"]
  end

  it "brotli_negotiated" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/vite/assets/application-def456.js",
      {"Accept-Encoding" => "gzip, br"})
      .should eq STATIC_EXPECTED["brotli_negotiated"]
  end

  it "gzip_negotiated" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/vite/assets/application-def456.js",
      {"Accept-Encoding" => "gzip"})
      .should eq STATIC_EXPECTED["gzip_negotiated"]
  end

  it "no_accept_encoding_identity" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/vite/assets/application-def456.js")
      .should eq STATIC_EXPECTED["no_accept_encoding_identity"]
  end

  it "missing_falls_through" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/vite/assets/nope.js")
      .should eq STATIC_EXPECTED["missing_falls_through"]
  end

  it "post_falls_through" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "POST", "/vite/assets/application-def456.js")
      .should eq STATIC_EXPECTED["post_falls_through"]
  end

  it "traversal_blocked" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "GET", "/../secret.txt")
      .should eq STATIC_EXPECTED["traversal_blocked"]
  end

  it "head_served" do
    addr = SpecStatic.addr.not_nil!
    static_call(addr, "HEAD", "/vite/assets/application-def456.js")
      .should eq STATIC_EXPECTED["head_served"]
  end

  # --- CRails extension (not in the gem): default stack serves hashed
  # vite assets with immutable caching.
  it "crails_default_immutable_on_vite_assets" do
    default_like = HTTP::Server.new { |ctx|
      CRails::Middleware::Static.new(ROOT).call(ctx)
    }
    addr = default_like.bind_tcp("127.0.0.1", 0)
    spawn { default_like.listen }
    sleep 50.milliseconds

    response = HTTP::Client.new(addr.address, addr.port) do |client|
      client.exec(HTTP::Request.new("GET", "/vite/assets/app-def456.css"))
    end
    response.status_code.should eq 200
    response.headers["Cache-Control"]?.should eq "public, max-age=31536000, immutable"

    default_like.close
  end

  # --- CRails extension (not in the gem): importmap modules are served
  # from app/javascript at /javascripts/* (asset pipeline replacement).
  it "crails_serves_javascripts_from_app_javascript" do    js_root = File.join(ROOT, "appjs")
    FileUtils.mkdir_p(File.join(js_root, "controllers"))
    File.write(File.join(js_root, "application.js"), "console.log(1)\n")
    File.write(File.join(js_root, "controllers", "greet.js"), "export {}\n")

    handler = HTTP::Server.new { |ctx|
      CRails::Middleware::Static.new(ROOT, javascripts_root: js_root).call(ctx)
    }
    addr = handler.bind_tcp("127.0.0.1", 0)
    spawn { handler.listen }
    sleep 50.milliseconds

    response = HTTP::Client.new(addr.address, addr.port) do |client|
      client.exec(HTTP::Request.new("GET", "/javascripts/application.js"))
    end
    response.status_code.should eq 200
    response.headers["Content-Type"].should eq "text/javascript"
    response.body.should eq "console.log(1)\n"

    nested = HTTP::Client.new(addr.address, addr.port) do |client|
      client.exec(HTTP::Request.new("GET", "/javascripts/controllers/greet.js"))
    end
    nested.status_code.should eq 200
    nested.body.should eq "export {}\n"

    missing = HTTP::Client.new(addr.address, addr.port) do |client|
      client.exec(HTTP::Request.new("GET", "/javascripts/nope.js"))
    end
    missing.status_code.should eq 404

    handler.close
  end
  # --- CRails extension (not in the gem): /assets/* resolved the
  # propshaft way — digest stripped from the URL, file looked up by
  # logical path under the assets root subdirs (Propshaft::Server port).
  it "crails_serves_assets_with_digest_stripping" do
    assets_root = File.join(ROOT, "appassets")
    FileUtils.mkdir_p(File.join(assets_root, "stylesheets"))
    FileUtils.mkdir_p(File.join(assets_root, "images", "flags"))
    File.write(File.join(assets_root, "stylesheets", "landing.css"), "body{color:#00ffcc}\n")
    File.write(File.join(assets_root, "images", "flags", "ru.png"), "png-ru")

    handler = HTTP::Server.new { |ctx|
      CRails::Middleware::Static.new(ROOT, assets_root: assets_root).call(ctx)
    }
    addr = handler.bind_tcp("127.0.0.1", 0)
    spawn { handler.listen }
    sleep 50.milliseconds

    # Stale digest in URL → resolved to the fresh source file.
    digested = HTTP::Client.new(addr.address, addr.port) do |client|
      client.exec(HTTP::Request.new("GET", "/assets/landing-d7970708.css"))
    end
    digested.status_code.should eq 200
    digested.headers["Content-Type"].should eq "text/css; charset=utf-8"
    digested.headers["Cache-Control"].should eq "public, max-age=31536000, immutable"
    digested.headers["ETag"]?.should_not be_nil
    digested.body.should eq "body{color:#00ffcc}\n"

    # Logical path (no digest) also resolves.
    logical = HTTP::Client.new(addr.address, addr.port) do |client|
      client.exec(HTTP::Request.new("GET", "/assets/landing.css"))
    end
    logical.status_code.should eq 200
    logical.body.should eq "body{color:#00ffcc}\n"

    # Nested logical path from another load-path dir.
    nested = HTTP::Client.new(addr.address, addr.port) do |client|
      client.exec(HTTP::Request.new("GET", "/assets/flags/ru.png"))
    end
    nested.status_code.should eq 200
    nested.headers["Content-Type"].should eq "image/png"
    nested.body.should eq "png-ru"

    # Unresolvable → 404 text/plain "Not found" (Propshaft::Server),
    # NOT a fall-through to the app.
    missing = HTTP::Client.new(addr.address, addr.port) do |client|
      client.exec(HTTP::Request.new("GET", "/assets/nope-1234567.css"))
    end
    missing.status_code.should eq 404
    missing.headers["Content-Type"].should eq "text/plain"
    missing.body.should eq "Not found"

    handler.close
  end
end

# Cleanup runs after the examples (they execute in at_exit).
Spec.after_suite { FileUtils.rm_rf(ROOT) }

# Documented deviations (also in src/static.cr):
# - Range requests and conditional 304s (Last-Modified/ETag) are P2.
# - CRails extension: /vite/assets/ gets immutable Cache-Control by
#   default (the gem's bare Static adds no headers).
