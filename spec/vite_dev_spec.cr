# ViteDevProxy spec: сквозной прогон через HTTP::Server с middleware
# [ViteDevProxy, fallback], где fallback — 404-маркер (запрос "ушёл в
# приложение"). Фейковый vite-сервер — HTTP::Server в отдельном
# fiber'е: отдаёт дев-ассеты, отвечает на HTTP-заголовки записью в
# class-переменную, ws-upgrade поднимает echo-сервер (как CableHandler
# в action_cable.cr). Оракул-байты dev-тегов — action_view.cr
# oracle/vite_dev_expected.yml; здесь проверяется транспортная часть
# (проксирование HTTP + ws-сплайсинг), до vite-сервера из спеков сеть
# не ходит.

require "spec"
require "../src/railties_cr"
require "http/web_socket"

# --- фейковый vite-сервер ------------------------------------------------

module FakeVite
  class_property addr : Socket::IPAddress?
  class_property hits = [] of {String, String, String} # {method, path, host}
  class_property forwarded = {} of String => String    # заголовки последнего запроса

  class Handler
    include HTTP::Handler

    def call(context : HTTP::Server::Context) : Nil
      request = context.request
      record(request)
      case request.path
      when "/@vite/client", "/vite/@vite/client"
        context.response.status_code = 200
        context.response.headers["Content-Type"] = "text/javascript"
        context.response.print "export default class ViteClient {}"
      when "/vite/entrypoints/application.js"
        context.response.status_code = 200
        context.response.headers["Content-Type"] = "text/javascript"
        context.response.print "console.log('dev entrypoint')"
      when "/src/main.js"
        context.response.status_code = 200
        context.response.headers["Content-Type"] = "text/javascript"
        context.response.print "export const main = 1"
      else
        if upgrade_request?(request)
          upgrade_ws(context)
        else
          context.response.status_code = 404
          context.response.print "no-vite"
        end
      end
    end

    private def record(request) : Nil
      FakeVite.hits << {request.method, request.path, request.headers["Host"]? || ""}
      FakeVite.forwarded["X-Forwarded-Host"] = request.headers["X-Forwarded-Host"]? || ""
      FakeVite.forwarded["X-Forwarded-Proto"] = request.headers["X-Forwarded-Proto"]? || ""
      FakeVite.forwarded["X-Forwarded-Port"] = request.headers["X-Forwarded-Port"]? || ""
      FakeVite.forwarded["Sec-WebSocket-Protocol"] = request.headers["Sec-WebSocket-Protocol"]? || ""
    end

    private def upgrade_request?(request : HTTP::Request) : Bool
      return false unless upgrade = request.headers["Upgrade"]?
      return false unless upgrade.compare("websocket", case_insensitive: true) == 0

      request.headers.includes_word?("Connection", "Upgrade")
    end

    private def upgrade_ws(context : HTTP::Server::Context) : Nil
      response = context.response
      key = request_key(context)
      unless key
        response.status_code = 400
        return
      end
      response.status_code = 101
      response.headers["Upgrade"] = "websocket"
      response.headers["Connection"] = "Upgrade"
      response.headers["Sec-WebSocket-Accept"] = HTTP::WebSocket::Protocol.key_challenge(key)
      if (proto = context.request.headers["Sec-WebSocket-Protocol"]?) &&
         proto.split(',').map(&.strip).includes?("vite-hmr")
        response.headers["Sec-WebSocket-Protocol"] = "vite-hmr"
      end
      response.upgrade do |io|
        ws = HTTP::WebSocket.new(io)
        ws.on_message { |message| ws.send("echo:#{message}") }
        ws.run
      end
    end

    private def request_key(context : HTTP::Server::Context) : String?
      context.request.headers["Sec-WebSocket-Key"]?
    end
  end
end

fake_vite = HTTP::Server.new([FakeVite::Handler.new] of HTTP::Handler)
FakeVite.addr = fake_vite.bind_tcp("127.0.0.1", 0)
spawn { fake_vite.listen }

# --- приложение под прокси ----------------------------------------------

class FallbackApp
  include HTTP::Handler

  def call(context : HTTP::Server::Context) : Nil
    context.response.status_code = 404
    context.response.headers["Content-Type"] = "text/plain"
    context.response.print "app-fallback"
  end
end

module ProxyUnderTest
  class_property addr : Socket::IPAddress?
end

vite_addr = FakeVite.addr.not_nil!
proxy = CRails::Middleware::ViteDevProxy.new(vite_addr.address, vite_addr.port)
proxy.enabled = true
proxy_server = HTTP::Server.new([proxy, FallbackApp.new] of HTTP::Handler)
ProxyUnderTest.addr = proxy_server.bind_tcp("127.0.0.1", 0)
spawn { proxy_server.listen }

sleep 50.milliseconds

def proxy_get(path : String, host : String? = nil) : HTTP::Client::Response
  addr = ProxyUnderTest.addr.not_nil!
  headers = HTTP::Headers.new
  headers["Host"] = host if host
  HTTP::Client.new(addr.address, addr.port) do |client|
    client.compress = false
    client.exec(HTTP::Request.new("GET", path, headers: headers))
  end
end

describe "vite dev proxy" do
  it "proxies /@vite/client to the vite server" do
    response = proxy_get("/@vite/client")
    response.status_code.should eq 200
    response.headers["Content-Type"].should eq "text/javascript"
    response.body.should eq "export default class ViteClient {}"
  end

  it "proxies same-origin entrypoints (/vite/...) to the vite server" do
    response = proxy_get("/vite/entrypoints/application.js")
    response.status_code.should eq 200
    response.body.should eq "console.log('dev entrypoint')"
    FakeVite.hits.last.should eq({"GET", "/vite/entrypoints/application.js",
      "#{FakeVite.addr.not_nil!.address}:#{FakeVite.addr.not_nil!.port}"})
  end

  it "proxies /src module requests" do
    response = proxy_get("/src/main.js")
    response.status_code.should eq 200
    response.body.should eq "export const main = 1"
  end

  it "rewrites Host and sets X-Forwarded-* like the gem" do
    addr = ProxyUnderTest.addr.not_nil!
    proxy_get("/@vite/client", "127.0.0.1:#{addr.port}")
    vite = FakeVite.addr.not_nil!
    FakeVite.forwarded["X-Forwarded-Host"].should eq "127.0.0.1:#{addr.port}"
    FakeVite.forwarded["X-Forwarded-Proto"].should eq "http"
    FakeVite.forwarded["X-Forwarded-Port"].should eq vite.port.to_s
    FakeVite.hits.last[2].should eq "#{vite.address}:#{vite.port}"
  end

  it "does not touch non-vite paths" do
    response = proxy_get("/docs/page")
    response.status_code.should eq 404
    response.body.should eq "app-fallback"
  end

  it "passes through when disabled" do
    addr = ProxyUnderTest.addr.not_nil!
    disabled = CRails::Middleware::ViteDevProxy.new(vite_addr.address, vite_addr.port)
    disabled.enabled = false
    server = HTTP::Server.new([disabled, FallbackApp.new] of HTTP::Handler)
    bound = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    sleep 50.milliseconds

    response = HTTP::Client.new(bound.address, bound.port) do |client|
      client.exec(HTTP::Request.new("GET", "/@vite/client"))
    end
    response.status_code.should eq 404
    response.body.should eq "app-fallback"
    server.close
  end

  it "falls through to the app when the vite server is down" do
    # Порт, на котором точно никто не слушает.
    dead = TCPServer.new("127.0.0.1", 0)
    dead_port = dead.local_address.port
    dead.close

    proxy_down = CRails::Middleware::ViteDevProxy.new("127.0.0.1", dead_port)
    proxy_down.enabled = true
    server = HTTP::Server.new([proxy_down, FallbackApp.new] of HTTP::Handler)
    bound = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    sleep 50.milliseconds

    response = HTTP::Client.new(bound.address, bound.port) do |client|
      client.exec(HTTP::Request.new("GET", "/@vite/client"))
    end
    response.status_code.should eq 404
    response.body.should eq "app-fallback"
    server.close
  end

  it "splices HMR websocket upgrades (vite-hmr subprotocol)" do
    addr = ProxyUnderTest.addr.not_nil!
    ws = HTTP::WebSocket.new(addr.address, "/", addr.port,
      headers: HTTP::Headers{"Sec-WebSocket-Protocol" => "vite-hmr"})
    got = Channel(String).new
    ws.on_message { |message| got.send(message) }
    spawn { ws.run }
    ws.send("hello-hmr")
    select
    when message = got.receive
      message.should eq "echo:hello-hmr"
    when timeout(3.seconds)
      fail "no message spliced back from the vite ws"
    end
    FakeVite.forwarded["Sec-WebSocket-Protocol"].should eq "vite-hmr"

    ws.close
  end

  it "does not hijack non-vite websocket upgrades (e.g. /cable)" do
    addr = ProxyUnderTest.addr.not_nil!
    # WS-upgrade без vite-hmr на пути вне дев-префиксов уходит в
    # приложение: FallbackApp отвечает 404 (handshake не завершён).
    socket = TCPSocket.new(addr.address, addr.port)
    socket << "GET / HTTP/1.1\r\nHost: #{addr.address}:#{addr.port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" \
              "Sec-WebSocket-Version: 13\r\n\r\n"
    socket.flush
    response = socket.gets.to_s
    response.should contain "404"
    socket.close
  end

  it "sits before Static in the dev default stack" do
    # Спек-процесс без CRAILS_ENV: CRails.env == development, прокси в
    # стеке (ветка CRAILS_VITE_DEV проверяется тем же enabled?).
    # HostAuthorization/AssumeSSL/SSL — всегда первые в стеке (читают
    # конфиг на call-time), как в Rails 8.1 до Sendfile/Static.
    config = CRails::Config.new
    names = config.middleware.map(&.name)
    names[0].should contain "HostAuthorization"
    names[1].should contain "AssumeSSL"
    names[2].should contain "SSL"
    names[3].should contain "ViteDevProxy"
    names[4].should contain "Static"
  end
end

Spec.after_suite do
  fake_vite.close
  proxy_server.close
end

# Documented deviations (also in src/vite_dev.cr):
# - fixed dev-path prefix list instead of the gem's vite_url_prefix +
#   file_in_vite_root? FS check; no Hanami/.ts.js-URI rewrites;
# - ws splicing is a CRails extension (Rack::Proxy cannot upgrade):
#   only dev paths and Sec-WebSocket-Protocol: vite-hmr upgrades;
# - HTTP https-mode (config.protocol) is not supported — vite behind
#   TLS is P2.
