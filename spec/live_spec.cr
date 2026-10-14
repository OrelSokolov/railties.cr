# Mirror of action_pack.cr/oracle/live_expected.yml (captured from
# actionpack 8.1.4 + puma 6.6.1 via action_pack.cr/oracle/live_cases.rb).
# Same case IDs, same expectations, no edits to the cases.
#
# Part A (sse_* / buffer_*): in-process FakeStream / bare
# HTTP::Server::Response — SSE wire bytes and Stream (Live::Buffer)
# semantics: SizedQueue(10) backpressure, abort, ClientDisconnected,
# close, ignore_disconnect.
# Part B (transport_*): the full CRails stack (middleware -> routes ->
# controller -> Live fiber split + pump) behind a real HTTP::Server,
# driven by raw TCP sockets: chunked framing, headers on first write,
# SSE over the wire, send_stream, error-before-commit (500),
# error-after-commit (partial frame), HTTP/1.0 fallback and
# client-disconnect cancellation of the action fiber.

require "spec"
require "json"
require "../src/railties_cr"

LIVE_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../../action_pack.cr/oracle/live_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

# --- Part A helpers -------------------------------------------------------

class FakeStream
  property chunks = [] of String
  property? closed = false

  def write(str : String) : Int32
    chunks << str
    str.bytesize
  end

  def close : Nil
    @closed = true
  end
end

def sse_bytes(object : String | JSON::Any::Type,
              ctor_event : String? = nil, ctor_id : Int32? = nil, ctor_retry : Int32? = nil,
              event : String? = nil, id : Int32? = nil, retry : Int32? = nil) : String
  io = FakeStream.new
  sse = ActionController::Live::SSE.new(io, event: ctor_event, id: ctor_id, retry: ctor_retry)
  sse.write(object, event: event, id: id, retry: retry)
  io.chunks.join
end

def live_buffer : {HTTP::Server::Response, ActionController::Live::Stream}
  response = HTTP::Server::Response.new(IO::Memory.new)
  {response, response.stream}
end

# --- Part A cases ---------------------------------------------------------

describe "ActionController::Live SSE wire (actionpack 8.1.4 oracle)" do
  it "sse_data" do
    sse_bytes("foo").inspect.should eq LIVE_EXPECTED["sse_data"]
  end

  it "sse_data_multiline" do
    sse_bytes("line1\nline2\n").inspect.should eq LIVE_EXPECTED["sse_data_multiline"]
  end

  it "sse_json_object" do
    sse_bytes({"name" => JSON::Any.new("John")} of String => JSON::Any).inspect
      .should eq LIVE_EXPECTED["sse_json_object"]
  end

  it "sse_json_nested" do
    obj = {"a" => JSON::Any.new([JSON::Any.new(1_i64), JSON::Any.new(2_i64)]),
           "b" => JSON::Any.new(nil)} of String => JSON::Any
    sse_bytes(obj).inspect.should eq LIVE_EXPECTED["sse_json_nested"]
  end

  it "sse_opts_order" do
    sse_bytes("x", id: 10, event: "greet", retry: 500).inspect
      .should eq LIVE_EXPECTED["sse_opts_order"]
  end

  it "sse_ctor_defaults" do
    sse_bytes("x", ctor_retry: 300, ctor_event: "event-name").inspect
      .should eq LIVE_EXPECTED["sse_ctor_defaults"]
  end

  it "sse_write_overrides_ctor" do
    sse_bytes("x", ctor_retry: 300, ctor_event: "a", event: "b", retry: 500).inspect
      .should eq LIVE_EXPECTED["sse_write_overrides_ctor"]
  end

  it "sse_falsy_id_omitted" do
    sse_bytes("x").inspect.should eq LIVE_EXPECTED["sse_falsy_id_omitted"]
  end

  it "sse_close_closes_stream" do
    io = FakeStream.new
    sse = ActionController::Live::SSE.new(io)
    sse.close
    io.closed?.to_s.should eq LIVE_EXPECTED["sse_close_closes_stream"]
  end
end

describe "ActionController::Live buffer (actionpack 8.1.4 oracle)" do
  it "buffer_queue_size_default" do
    ActionController::Live::Stream.queue_size.to_s
      .should eq LIVE_EXPECTED["buffer_queue_size_default"]
  end

  it "buffer_write_headers" do
    response, buffer = live_buffer
    response.headers["Content-Length"] = "999"
    buffer.write("x")
    "#{response.headers["Cache-Control"]}|cl:#{response.headers["Content-Length"]?.inspect}|" \
      "committed:#{buffer.committed?.to_s}"
      .should eq LIVE_EXPECTED["buffer_write_headers"]
  end

  it "buffer_write_returns_bytesize" do
    _, buffer = live_buffer
    buffer.write("héllo").to_s.should eq LIVE_EXPECTED["buffer_write_returns_bytesize"]
  end

  it "buffer_writeln_appends" do
    _, buffer = live_buffer
    buffer.writeln("tick")
    buffer.close
    parts = [] of String
    while (chunk = buffer.pop)
      parts << chunk
    end
    parts.join.inspect.should eq LIVE_EXPECTED["buffer_writeln_appends"]
  end

  it "buffer_writeln_keeps_trailing" do
    _, buffer = live_buffer
    buffer.writeln("tick\n")
    buffer.close
    parts = [] of String
    while (chunk = buffer.pop)
      parts << chunk
    end
    parts.join.inspect.should eq LIVE_EXPECTED["buffer_writeln_keeps_trailing"]
  end

  it "buffer_backpressure_blocks" do
    _, buffer = live_buffer
    done = Channel(Bool).new
    spawn do
      (buffer.class.queue_size + 1).times { |i| buffer.write("c#{i}") }
      done.send(true)
    end
    sleep 150.milliseconds
    # неблокирующая проверка: канал всё ещё пуст — fiber заблокирован
    # на (queue_size+1)-й записи
    progressed = select
      when done.receive
        true
      when timeout(0.seconds)
        false
    end
    # progressed=false → продюсер заблокирован (в оракуле blocked=true)
    (!progressed).to_s.should eq LIVE_EXPECTED["buffer_backpressure_blocks"]
  end

  it "buffer_backpressure_unblocks" do
    _, buffer = live_buffer
    done = Channel(Bool).new
    spawn do
      (buffer.class.queue_size + 1).times { |i| buffer.write("c#{i}") }
      done.send(true)
    end
    sleep 150.milliseconds # заблокирован на 11-м push
    popped = buffer.pop     # освободить один слот
    finished = select
      when done.receive
        true
      when timeout(2.seconds)
        false
    end
    "#{popped.inspect}|#{finished ? "unblocked" : "stuck"}"
      .should eq LIVE_EXPECTED["buffer_backpressure_unblocks"]
  end

  it "buffer_write_after_abort" do
    _, buffer = live_buffer
    buffer.abort
    value = begin
      buffer.write("x")
      "no-raise"
    rescue ex : ActionController::Live::ClientDisconnected
      "raise:ClientDisconnected"
    end
    value.should eq LIVE_EXPECTED["buffer_write_after_abort"]
  end

  it "buffer_ignore_disconnect" do
    _, buffer = live_buffer
    buffer.ignore_disconnect = true
    buffer.abort
    buffer.write("x").to_s.should eq LIVE_EXPECTED["buffer_ignore_disconnect"]
  end

  it "buffer_connected_after_abort" do
    _, buffer = live_buffer
    before = buffer.connected?
    buffer.abort
    "#{before}#{buffer.connected?}".should eq LIVE_EXPECTED["buffer_connected_after_abort"]
  end

  it "buffer_closed_write" do
    _, buffer = live_buffer
    buffer.close
    value = begin
      buffer.write("x")
      "no-raise"
    rescue ex : IO::Error
      "raise:closed"
    end
    value.should eq LIVE_EXPECTED["buffer_closed_write"]
  end
end

# --- Part B: app + server over raw TCP ------------------------------------

class LiveTransportController < ActionController::Base
  include ActionController::Live

  def chunked
    response.headers["Content-Type"] = "text/plain"
    response.stream.write "hello "
    response.stream.write "world"
  ensure
    response.stream.close
  end

  def sse
    response.headers["Content-Type"] = "text/event-stream"
    sse = ActionController::Live::SSE.new(response.stream)
    sse.write "a"
    sse.write({"name" => JSON::Any.new("John")} of String => JSON::Any,
              event: "greet", id: 10, retry: 500)
  ensure
    sse.try(&.close)
  end

  def csv
    send_stream(filename: "subscribers.csv", type: "text/csv") do |stream|
      stream.write "email\n"
      stream.write "a@b.c\n"
    end
  end

  def error_before_commit
    response.headers["Content-Type"] = "text/event-stream"
    raise "boom"
  end

  def error_after_commit
    response.headers["Content-Type"] = "text/event-stream"
    response.stream.write "partial"
    raise "boom-mid-stream"
  ensure
    response.stream.close
  end
end

LIVE_DISCONNECT = Channel({String, Int32}).new

class LiveDisconnectController < ActionController::Base
  include ActionController::Live

  def infinite
    response.headers["Content-Type"] = "text/event-stream"
    writes = 0
    10_000.times do |i|
      response.stream.writeln "tick #{i}"
      writes += 1
      sleep 20.milliseconds
    end  rescue ex : ActionController::Live::ClientDisconnected
    LIVE_DISCONNECT.send({"rescued:ClientDisconnected", writes})
  ensure
    response.stream.close
  end
end

APP_LIVE = CRails::Application.new.tap do |app|
  app.routes.draw do
    get "/chunked", to: "live_transport#chunked"
    get "/sse", to: "live_transport#sse"
    get "/csv", to: "live_transport#csv"
    get "/error_before_commit", to: "live_transport#error_before_commit"
    get "/error_after_commit", to: "live_transport#error_after_commit"
    get "/infinite", to: "live_disconnect#infinite"
  end
end

module SpecLive
  class_property addr : Socket::IPAddress?
end

live_server = HTTP::Server.new { |ctx| APP_LIVE.call(ctx) }
SpecLive.addr = live_server.bind_tcp("127.0.0.1", 0)
spawn { live_server.listen }
sleep 50.milliseconds

def live_raw_request(path : String, http_version : String = "1.1",
                     close_client_after : Int32? = nil, read_seconds : Float64 = 2.0) : String
  addr = SpecLive.addr.not_nil!
  sock = TCPSocket.new(addr.address, addr.port)
  sock << "GET #{path} HTTP/#{http_version}\r\nHost: localhost\r\n\r\n"
  data = IO::Memory.new
  done = Channel(Nil).new(1)
  limit = close_client_after
  spawn do
    slice = Bytes.new(65_536)
    loop do
      n = sock.read(slice)
      break if n == 0
      data.write(slice[0, n])
      break if data.to_s.ends_with?("0\r\n\r\n")
      break if limit && data.bytesize >= limit
    end
  rescue ex : IO::Error
  ensure
    done.send(nil)
  end
  select
    when done.receive
    when timeout(read_seconds.seconds)
  end
  sock.close
  data.to_s
end

# [status, {header => value}, body]; имена заголовков в нижний регистр
def live_parse_response(raw : String) : {String, Hash(String, String), String}
  head, body = raw.split("\r\n\r\n", 2)
  status = raw[/\AHTTP\/\d\.\d (\d+)/, 1] || ""
  headers = {} of String => String
  head.split("\r\n").skip(1).each do |line|
    k, v = line.split(":", 2)
    headers[k.strip.downcase] = v.strip
  end
  {status, headers, body}
end

def live_decode_chunks(body : String) : Array(String)
  chunks = [] of String
  pos = 0
  while pos < body.bytesize
    nl = body.index("\r\n", pos) || break
    size = body.byte_slice(pos, nl - pos).to_i64(16, prefix: true)
    break if size == 0
    start = nl + 2
    break if start + size > body.bytesize
    chunks << body.byte_slice(start, size)
    pos = start + size + 2
  end
  chunks
end

describe "ActionController::Live transport (actionpack 8.1.4 oracle)" do
  it "transport_chunked_status_headers" do
    status, headers, _body = live_parse_response(live_raw_request("/chunked"))
    "#{status}|cc:#{headers["cache-control"]?}|cl:#{headers.has_key?("content-length")}|" \
      "te:#{headers["transfer-encoding"]?}|ct:#{headers["content-type"]?}"
      .should eq LIVE_EXPECTED["transport_chunked_status_headers"]
  end

  it "transport_chunked_frames" do
    _status, headers, body = live_parse_response(live_raw_request("/chunked"))
    frames = headers["transfer-encoding"]? ? live_decode_chunks(body) : [body]
    "#{frames.size}:#{frames.map(&.inspect).join("|")}"
      .should eq LIVE_EXPECTED["transport_chunked_frames"]
  end

  it "transport_sse_wire" do
    _status, headers, body = live_parse_response(live_raw_request("/sse"))
    frames = headers["transfer-encoding"]? ? live_decode_chunks(body) : [body]
    "#{headers["content-type"]?}|cc:#{headers["cache-control"]?}|" \
      "frames:#{frames.map(&.inspect).join("|")}"
      .should eq LIVE_EXPECTED["transport_sse_wire"]
  end

  it "transport_send_stream" do
    status, headers, body = live_parse_response(live_raw_request("/csv"))
    "#{status}|ct:#{headers["content-type"]?}|cd:#{headers["content-disposition"]?}|" \
      "cc:#{headers["cache-control"]?}|body:#{body.inspect}"
      .should eq LIVE_EXPECTED["transport_send_stream"]
  end

  it "transport_error_before_commit_500" do
    status, _h, _b = live_parse_response(live_raw_request("/error_before_commit"))
    status.should eq LIVE_EXPECTED["transport_error_before_commit_500"]
  end

  it "transport_error_after_commit_partial" do
    _status, headers, body = live_parse_response(live_raw_request("/error_after_commit"))
    frames = headers["transfer-encoding"]? ? live_decode_chunks(body) : [body]
    frames.map(&.inspect).join("|")
      .should eq LIVE_EXPECTED["transport_error_after_commit_partial"]
  end

  it "transport_http10_no_chunked" do
    _status, headers, body = live_parse_response(
      live_raw_request("/chunked", http_version: "1.0", read_seconds: 3.0))
    "te:#{headers.has_key?("transfer-encoding")}|body:#{body.inspect}"
      .should eq LIVE_EXPECTED["transport_http10_no_chunked"]
  end

  it "transport_disconnect_cancels_action" do
    got = live_raw_request("/infinite", close_client_after: 64)
    state = select
      when value = LIVE_DISCONNECT.receive
        value
      when timeout(5.seconds)
        nil
    end
    "got:#{got.bytesize > 0}|state:#{state ? state[0] : "none"}"
      .should eq LIVE_EXPECTED["transport_disconnect_cancels_action"]
  end
end
