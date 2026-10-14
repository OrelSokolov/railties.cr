# Oracle cases for ActionDispatch::Static (P0 of the Vite integration:
# serving public/, where `vite build` drops hashed assets).
#
# Run against the ORIGINAL gem:
#   ruby oracle/static_cases.rb > oracle/static_expected.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in railties.cr/spec/
# static_spec.cr. The fallback app answers "404-fallback" so pass-through
# is distinguishable from serving.

gem "actionpack", "= 8.1.4"
gem "rack", "~> 3"
require "rack/files"
require "rack/mock"
require "action_dispatch"
require "action_controller"
require "action_dispatch/middleware/static"
require "fileutils"

def render(v)
  case v
  when String then v.gsub("\n", "\\n")
  else v.inspect
  end
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

ROOT = File.expand_path("static_fixture", __dir__)
FileUtils.rm_rf(ROOT)
FileUtils.mkdir_p(File.join(ROOT, "vite/assets"))
FileUtils.mkdir_p(File.join(ROOT, "docs"))
File.write(File.join(ROOT, "vite/assets/application-def456.js"), "console.log(1)\n")
File.write(File.join(ROOT, "vite/assets/application-def456.js.br"), "br-data")
File.write(File.join(ROOT, "vite/assets/application-def456.js.gz"), "gz-data")
File.write(File.join(ROOT, "vite/assets/app-def456.css"), "body{}\n")
File.write(File.join(ROOT, "vite/assets/logo-789.png"), "png")
File.write(File.join(ROOT, "docs/index.html"), "<h1>docs</h1>")

FALLBACK = ->(env) { [404, { "Content-Type" => "text/plain" }, ["404-fallback"]] }

def call(app, method, path, headers = {})
  env = Rack::MockRequest.env_for(path, method: method)
  headers.each { |k, v| env[k] = v }
  status, hs, body = app.call(env)
  ct = hs["Content-Type"] || hs["content-type"] || ""
  cc = hs["Cache-Control"] || hs["cache-control"] || ""
  ce = hs["Content-Encoding"] || hs["content-encoding"] || ""
  vary = hs["Vary"] || hs["vary"] || ""
  chunks = []
  body.each { |c| chunks << c }
  [status, ct, cc, ce, vary, chunks.join].join("|")
end

PLAIN  = ActionDispatch::Static.new(FALLBACK, ROOT)
IMMUTABLE = ActionDispatch::Static.new(
  FALLBACK, ROOT, headers: { "Cache-Control" => "public, max-age=31536000, immutable" })

# --- serving files --------------------------------------------------------

case_run("js_200") { call(PLAIN, :get, "/vite/assets/application-def456.js") }
case_run("css_200") { call(PLAIN, :get, "/vite/assets/app-def456.css") }
case_run("png_200") { call(PLAIN, :get, "/vite/assets/logo-789.png") }
case_run("index_html") { call(PLAIN, :get, "/docs/") }
case_run("dot_html") { call(PLAIN, :get, "/docs") }

# --- headers config -------------------------------------------------------

case_run("immutable_cache_control") do
  call(IMMUTABLE, :get, "/vite/assets/application-def456.js")
end

# --- precompressed --------------------------------------------------------

case_run("brotli_negotiated") do
  call(PLAIN, :get, "/vite/assets/application-def456.js",
       { "HTTP_ACCEPT_ENCODING" => "gzip, br" })
end
case_run("gzip_negotiated") do
  call(PLAIN, :get, "/vite/assets/application-def456.js",
       { "HTTP_ACCEPT_ENCODING" => "gzip" })
end
case_run("no_accept_encoding_identity") do
  call(PLAIN, :get, "/vite/assets/application-def456.js")
end

# --- pass-through ---------------------------------------------------------

case_run("missing_falls_through") { call(PLAIN, :get, "/vite/assets/nope.js") }
case_run("post_falls_through") { call(PLAIN, :post, "/vite/assets/application-def456.js") }
case_run("traversal_blocked") { call(PLAIN, :get, "/../secret.txt") }
case_run("head_served") { call(PLAIN, :head, "/vite/assets/application-def456.js") }
