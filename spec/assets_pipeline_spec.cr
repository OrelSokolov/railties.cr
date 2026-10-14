# Dev/prod паритет asset pipeline (фаза 4 плана): одно и то же
# приложение в dev (резолвер static.cr по app/assets, без сборки) и в
# prod (precompiled public/assets) отдаёт байт-одинаковые тела по
# байтово-одинаковым logical-путям. Заголовки — по static.cr (immutable/
# ETag/Vary), прекомпрессия .gz проверяется через Accept-Encoding.

require "spec"
require "../src/railties_cr"
require "file_utils"
require "compress/gzip"

Propshaft.logger = IO::Memory.new # "Writing ..." — не в вывод спеков

PARITY_ROOT = File.join(Dir.tempdir, "crails_assets_parity_#{Random::Secure.hex(4)}")
PARITY_ASSETS = File.join(PARITY_ROOT, "app/assets")

FileUtils.mkdir_p([File.join(PARITY_ASSETS, "stylesheets"), File.join(PARITY_ASSETS, "images")])
File.write(File.join(PARITY_ASSETS, "stylesheets", "application.css"),
  %(/* parity */\n.logo { background: url("logo.svg"); }\n))
File.write(File.join(PARITY_ASSETS, "images", "logo.svg"),
  %(<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>\n))

# --- prod: прекомпилируем в public/assets (как `crails assets:precompile`)
def build_parity_assets : {Propshaft::Manifest, String}
  config = Propshaft::Config.new
  config.paths = [File.join(PARITY_ASSETS, "stylesheets"), File.join(PARITY_ASSETS, "images")]
  config.version = "1"
  config.output_path = File.join(PARITY_ROOT, "public/assets")
  config.manifest_path = File.join(PARITY_ROOT, "public/assets/.manifest.json")
  config.versions = [".gz"]
  assembly = Propshaft::Assembly.new(config)
  assembly.processor.process
  {assembly.load_path.manifest, File.join(PARITY_ROOT, "public/assets")}
end

PARITY_RESULT = build_parity_assets
PARITY_MANIFEST = PARITY_RESULT[0]
DIGESTED_CSS = PARITY_MANIFEST["application.css"].not_nil!.digested_path

class ParityFallback
  include HTTP::Handler

  def call(context : HTTP::Server::Context) : Nil
    context.response.status_code = 404
  end
end

# DEV: root указывает на несуществующий public — всё через propshaft-
# резолвер по app/assets (логический путь и digest-путь).
dev_server = HTTP::Server.new([
  CRails::Middleware::Static.new(File.join(PARITY_ROOT, "nowhere-public"),
    assets_root: PARITY_ASSETS),
  ParityFallback.new,
] of HTTP::Handler)
dev_addr = dev_server.bind_tcp("127.0.0.1", 0)
spawn { dev_server.listen }

# PROD: обычная статика из public/ (digest-файлы + .gz соседи).
prod_server = HTTP::Server.new([
  CRails::Middleware::Static.new(File.join(PARITY_ROOT, "public")),
  ParityFallback.new,
] of HTTP::Handler)
prod_addr = prod_server.bind_tcp("127.0.0.1", 0)
spawn { prod_server.listen }
sleep 50.milliseconds

def get(addr, path, accept_encoding : String? = nil) : HTTP::Client::Response
  headers = HTTP::Headers.new
  headers["Accept-Encoding"] = accept_encoding if accept_encoding
  HTTP::Client.new(addr.address, addr.port) do |client|
    client.compress = false
    client.exec(HTTP::Request.new("GET", path, headers: headers))
  end
end

describe "asset pipeline dev/prod parity" do
  it "dev serves compiled css by logical and digested paths" do
    body = get(dev_addr, "/assets/application.css").body
    body.should contain(%(url("/assets/#{PARITY_MANIFEST["logo.svg"].not_nil!.digested_path}")))
    get(dev_addr, "/assets/#{DIGESTED_CSS}").body.should eq body
  end

  it "prod serves the same bytes by the same digested path" do
    dev_body = get(dev_addr, "/assets/#{DIGESTED_CSS}").body
    prod = get(prod_addr, "/assets/#{DIGESTED_CSS}")
    prod.status_code.should eq 200
    prod.headers["Content-Type"].should eq "text/css"
    prod.body.should eq dev_body
  end

  it "prod serves the precompressed .gz neighbour" do
    gz = get(prod_addr, "/assets/#{DIGESTED_CSS}", accept_encoding: "gzip")
    gz.status_code.should eq 200
    gz.headers["Content-Encoding"].should eq "gzip"
    gz.headers["Vary"].should eq "accept-encoding"
    plain = get(prod_addr, "/assets/#{DIGESTED_CSS}").body
    decompressed = nil
    gz.body.to_slice.try do |slice|
      decompressed = Compress::Gzip::Reader.open(IO::Memory.new(slice), &.gets_to_end)
    end
    decompressed.should eq plain
  end

  it "dev 404s for a missing logical path" do
    response = get(dev_addr, "/assets/nope-1234567.css")
    response.status_code.should eq 404
    response.body.should eq "Not found"
  end
end

Spec.after_suite do
  dev_server.close
  prod_server.close
  FileUtils.rm_rf(PARITY_ROOT)
end
