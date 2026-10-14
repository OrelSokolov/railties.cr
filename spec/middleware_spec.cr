# Oracle spec: the Crystal port must reproduce
# oracle/middleware_expected.yml (captured from rails 8.1.4 via
# oracle/middleware_cases.rb). Same case IDs, same expectations, no
# edits on either side. Known deviations are asserted explicitly with
# (deviation) markers and listed at the bottom of this file.

require "spec"
require "log"
require "../src/railties_cr"

MW_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/middleware_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

# --- scratch middleware classes (same names as the oracle script) ----
{% for name in %w[One Two Three Four Five Six] %}
  class {{name.id}}
    include HTTP::Handler

    def call(context : HTTP::Server::Context) : Nil
      call_next(context)
    end
  end
{% end %}

# A custom middleware, inserted from config like the oracle's
# config/initializers/oracle_middleware.rb does in the Rails app.
class OracleHeaderMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context) : Nil
    # Set before call_next so headers are modifiable even if the
    # response body below was flushed mid-stream.
    context.response.headers["X-Oracle-Mw"] = "oracle-mw-1"
    call_next(context)
  end
end

MW_APP = CRails::Application.new
MW_APP.config.middleware.insert_before(CRails::Middleware::RequestId, OracleHeaderMiddleware)

server = HTTP::Server.new do |context|
  MW_APP.call(context)
end

module MwEnv
  class_property addr : Socket::IPAddress?
end

MwEnv.addr = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }
sleep 50.milliseconds

def mw_request(method : String, path : String)
  addr = MwEnv.addr.not_nil!
  HTTP::Client.new(addr.address, addr.port) do |client|
    client.exec(HTTP::Request.new(method, path))
  end
end

def mw_names(stack : CRails::MiddlewareStack) : String
  stack.map(&.name).join(",")
end

def mw_new_stack(*klasses : HTTP::Handler.class) : CRails::MiddlewareStack
  s = CRails::MiddlewareStack.new
  klasses.each { |k| s.use(k) }
  s
end

describe "middleware stack (rails 8.1.4 oracle)" do
  # --- MiddlewareStack semantics --------------------------------------
  it "ops_use" do
    mw_names(mw_new_stack(One, Two)).should eq MW_EXPECTED["ops_use"]
  end

  it "ops_unshift" do
    s = mw_new_stack(One, Two)
    s.unshift(Three)
    mw_names(s).should eq MW_EXPECTED["ops_unshift"]
  end

  it "ops_insert_before" do
    s = mw_new_stack(One, Two)
    s.insert_before(Two, Three)
    mw_names(s).should eq MW_EXPECTED["ops_insert_before"]
  end

  it "ops_insert_after" do
    s = mw_new_stack(One, Two)
    s.insert_after(One, Three)
    mw_names(s).should eq MW_EXPECTED["ops_insert_after"]
  end

  it "ops_swap" do
    s = mw_new_stack(One, Two)
    s.swap(One, Three)
    mw_names(s).should eq MW_EXPECTED["ops_swap"]
  end

  it "ops_delete" do
    s = mw_new_stack(One, Two)
    s.delete(Two)
    mw_names(s).should eq MW_EXPECTED["ops_delete"]
  end

  it "ops_delete_missing_stays" do
    s = mw_new_stack(One, Two)
    s.delete(Three).should be_false # Ruby returns nil (not found)
    mw_names(s).should eq MW_EXPECTED["ops_delete_missing_stays"]
  end

  it "ops_delete_bang_missing" do
    s = mw_new_stack(One)
    # (deviation) Crystal raises Exception, Ruby RuntimeError — same message.
    ex = expect_raises Exception, MW_EXPECTED["ops_delete_bang_missing"].split(":", 3)[2] do
      s.delete!(Two)
    end
    ex.class.name.should eq "Exception"
  end

  it "ops_move_before" do
    s = mw_new_stack(One, Two, Three)
    s.move_before(One, Three)
    mw_names(s).should eq MW_EXPECTED["ops_move_before"]
  end

  it "ops_move_after" do
    s = mw_new_stack(One, Two, Three)
    s.move_after(One, Three)
    mw_names(s).should eq MW_EXPECTED["ops_move_after"]
  end

  it "ops_insert_before_missing" do
    s = mw_new_stack(One)
    # (deviation) Exception vs RuntimeError, same message.
    expect_raises(Exception, MW_EXPECTED["ops_insert_before_missing"].split(":", 3)[2]) do
      s.insert_before(Four, Two)
    end
  end

  it "ops_insert_after_missing" do
    s = mw_new_stack(One)
    expect_raises(Exception, MW_EXPECTED["ops_insert_after_missing"].split(":", 3)[2]) do
      s.insert_after(Four, Two)
    end
  end

  it "ops_swap_missing" do
    s = mw_new_stack(One)
    expect_raises(Exception, MW_EXPECTED["ops_swap_missing"].split(":", 3)[2]) do
      s.swap(Four, Two)
    end
  end

  it "ops_size_last_index" do
    s = mw_new_stack(One, Two, Three)
    "#{s.size}:#{s.last.name}:#{s[0].name}".should eq MW_EXPECTED["ops_size_last_index"]
  end

  it "middleware_equality" do
    s = mw_new_stack(One)
    node = s[0]
    "#{node == One}:#{node == Two}:#{node == s[0]}".should eq MW_EXPECTED["middleware_equality"]
  end

  it "middleware_inspect" do
    s = mw_new_stack(One)
    s[0].to_s.should eq MW_EXPECTED["middleware_inspect"]
  end

  it "build_head_class" do
    s = mw_new_stack(One, Two)
    s.build(TerminalHandler.new).class.name.should eq MW_EXPECTED["build_head_class"]
  end

  it "build_wires_app" do
    s = mw_new_stack(One, Two)
    head = s.build(TerminalHandler.new).as(One)
    head.next.not_nil!.as(HTTP::Handler).class.name.should eq MW_EXPECTED["build_wires_app"]
  end

  # --- HTTP behavior through the stack ---------------------------------
  it "head_up_status" do
    mw_request("HEAD", "/up").status_code.to_s.should eq MW_EXPECTED["head_up_status"]
  end

  it "head_up_body_empty" do
    (mw_request("HEAD", "/up").body.empty? ? "empty" : "non-empty")
      .should eq MW_EXPECTED["head_up_body_empty"]
  end

  it "head_up_content_type" do
    mw_request("HEAD", "/up").headers["Content-Type"].should eq MW_EXPECTED["head_up_content_type"]
  end

  it "head_up_content_length" do
    mw_request("HEAD", "/up").headers["Content-Length"]?.should eq MW_EXPECTED["head_up_content_length"]
  end

  it "head_up_x_request_id" do
    rid = mw_request("HEAD", "/up").headers["X-Request-Id"]? || ""
    result = rid =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/ ? "UUID" : rid
    result.should eq MW_EXPECTED["head_up_x_request_id"]
  end

  it "x_runtime_header" do
    v = mw_request("GET", "/up").headers["X-Runtime"]?
    (v.nil? ? "absent" : "present").should eq MW_EXPECTED["x_runtime_header"]
  end

  it "x_runtime_format" do
    v = mw_request("GET", "/up").headers["X-Runtime"]?
    result = v.nil? ? "absent" : (v =~ /\A\d+\.\d+\z/ ? "NUM" : v)
    result.should eq MW_EXPECTED["x_runtime_format"]
  end

  it "custom_insert_before_header" do
    mw_request("GET", "/up").headers["X-Oracle-Mw"]?.should eq MW_EXPECTED["custom_insert_before_header"]
  end

  # --- CRails specifics (not 1:1 with the Rails oracle list) ----------
  it "crails default stack" do
    # (deviation) the CRails default stack covers the Rails 8.1 entries
    # that have a counterpart — see middleware.cr header for the mapping.
    # In dev mode ViteDevProxy is prepended (CRails extension, see
    # vite_dev.cr; Rails has no counterpart — vite_ruby mounts a
    # Rack::Proxy in dev only).
    expected = [] of String
    # HostAuthorization/AssumeSSL/SSL are always in the CRails stack and
    # read config.hosts/assume_ssl/force_ssl at call time (Rails inserts
    # them conditionally at boot — documented deviation).
    expected.concat(["CRails::Middleware::HostAuthorization",
                     "CRails::Middleware::AssumeSSL",
                     "CRails::Middleware::SSL"])
    if CRails.env.development? || ENV["CRAILS_VITE_DEV"]? == "1"
      expected << "CRails::Middleware::ViteDevProxy"
    end
    expected.concat(["CRails::Middleware::Static",
                     "CRails::Middleware::RequestId",
                     "CRails::Middleware::RequestLogger",
                     "CRails::Middleware::ContentSecurityPolicy",
                     "CRails::Middleware::ShowExceptions",
                     "CRails::Middleware::Head"])
    mw_names(CRails::Application.new.config.middleware).should eq(expected.join(","))
  end

  it "print_middleware output (rake middleware analog)" do
    io = IO::Memory.new
    MW_APP.print_middleware(io)
    expected = [] of String
    expected.concat(["use CRails::Middleware::HostAuthorization",
                     "use CRails::Middleware::AssumeSSL",
                     "use CRails::Middleware::SSL"])
    if CRails.env.development? || ENV["CRAILS_VITE_DEV"]? == "1"
      expected << "use CRails::Middleware::ViteDevProxy"
    end
    expected.concat(["use CRails::Middleware::Static",
                     "use OracleHeaderMiddleware",
                     "use CRails::Middleware::RequestId",
                     "use CRails::Middleware::RequestLogger",
                     "use CRails::Middleware::ContentSecurityPolicy",
                     "use CRails::Middleware::ShowExceptions",
                     "use CRails::Middleware::Head"])
    io.to_s.lines.map(&.chomp).should eq(expected)
  end

  it "use appends innermost and still runs" do
    app = CRails::Application.new
    app.config.middleware.use(TailMarkerMiddleware)
    server2 = HTTP::Server.new { |ctx| app.call(ctx) }
    addr2 = server2.bind_tcp("127.0.0.1", 0)
    spawn { server2.listen }
    sleep 50.milliseconds
    HTTP::Client.new(addr2.address, addr2.port) { |c| c.get("/up") }
      .headers["X-Tail-Marker"]?.should eq "1"
  end
end

class TerminalHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context) : Nil
    context.response.status_code = 200
  end
end

class TailMarkerMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context) : Nil
    context.response.headers["X-Tail-Marker"] = "1"
    call_next(context)
  end
end

# Known deviations from the rails 8.1.4 oracle (all deliberate):
# 1. default_stack_names (Rails lists 28 entries incl. HostAuthorization,
#    Static, Executor, Cookies/Session/Flash, CSP, ETag...) is not
#    mirrored 1:1: CRails' default stack covers RequestId/Logger/
#    ShowExceptions/Head; Cookies/Session/Flash stay controller-side
#    (no per-request env to preload jars into), the rest have no
#    counterpart yet (see railties.cr/src/middleware.cr header).
# 2. Ruby RuntimeError -> Crystal Exception (same messages).
# 3. Middleware nodes take no constructor args/blocks — configurable
#    middleware read CRails.application.config at call time.
# 4. build() wires HTTP::Handler#next (Ruby passes the next middleware
#    to the constructor); no InstrumentationProxy (Notifications-
#    instrumented per-middleware execution is a possible P2).
