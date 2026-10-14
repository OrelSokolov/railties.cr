# CRails::Middleware::ViteDevProxy — дев-прокси на Vite dev-сервер.
#
# Референс: vite_ruby 3.9.2 lib/vite_ruby/dev_server_proxy.rb
# (ViteRuby::DevServerProxy < Rack::Proxy). Гем перехватывает пути с
# префиксом public_output_dir ("/vite/") и файлы из sourceCodeDir и
# переписывает Host/X-Forwarded-* на vite-сервер; WebSocket он не
# проксирует (Rack::Proxy не умеет upgrade) — ws-сплайсинг ниже является
# CRails-расширением: HMR-клиент vite (@vite/client) ходит на тот же
# origin с Sec-WebSocket-Protocol: vite-hmr, такие upgrade-запросы
# сплайсятся с TCP-сокетом vite-сервера в обе стороны.
#
# Включение: middleware добавляется в дефолтный стек только в dev-режиме
# (Config#initialize: CRails.env.development? || CRAILS_VITE_DEV=1).
# Хост/порт vite-сервера — CRAILS_VITE_HOST / CRAILS_VITE_PORT (дефолт
# 127.0.0.1:5173, как у vite). Если сервер не отвечает, запрос
# уходит дальше по стеку (аналог dev_server_running? == false в геме,
# уводящего в @app).
#
# Проксируемые пути (задокументированное подмножество vite dev-URL):
# /@vite (HMR-клиент), /@id, /@fs, /@react-refresh, /src,
# /node_modules (пребандл зависимостей), /vite/ (entrypoints и ассеты,
# пока манифеста нет — в dev его и не бывает).
#
# Задокументированные отклонения от гема:
# - нет rewrite_uri_for_vite (/.ts.js, /…​.css-нормализация Hanami/
#   stylesheet_link_tag) и file_in_vite_root?-проверки по ФС —
#   фиксированный список префиксов;
# - streaming: ответ vite читается в сокет приложения напрямую
#   (IO.copy), без буферизации тела;
# - ws: перехватываются только upgrade-запросы дев-путей и HMR
#   (Sec-WebSocket-Protocol: vite-hmr) — чужие ws (например /cable
#   action_cable.cr) не затрагиваются.

require "http/client"
require "socket"

module CRails
  module Middleware
    class ViteDevProxy
      include HTTP::Handler

      DEV_PATH_PREFIXES = {"/@vite", "/@id", "/@fs", "/@react-refresh",
                            "/src", "/node_modules", "/vite/"}

      property host : String
      property port : Int32
      # nil — авто-включение по env (dev-режим / CRAILS_VITE_DEV=1);
      # true/false — явное управление (тесты).
      @enabled : Bool? = nil

      def initialize(@host : String = ENV["CRAILS_VITE_HOST"]? || "127.0.0.1",
                     @port : Int32 = (ENV["CRAILS_VITE_PORT"]? || "5173").to_i)
      end

      def enabled? : Bool
        case forced = @enabled
        when Bool then forced
        else          CRails.env.development? || ENV["CRAILS_VITE_DEV"]? == "1"
        end
      end

      def enabled=(value : Bool?) : Nil
        @enabled = value
      end

      def call(context : HTTP::Server::Context) : Nil
        request = context.request
        if enabled? && (vite_path?(request.path) ||
                        (websocket_upgrade?(request) && vite_hmr?(request)))
          begin
            websocket_upgrade?(request) ? proxy_websocket(context) : proxy_http(context)
            return
          rescue ex : Socket::Error | IO::Error
            CRails.logger.debug { "vite dev server (#{host}:#{port}) not reachable: #{ex.class}" }
          end
        end
        call_next(context)
      end

      private def vite_path?(path : String) : Bool
        DEV_PATH_PREFIXES.any? { |prefix| path.starts_with?(prefix) }
      end

      private def websocket_upgrade?(request : HTTP::Request) : Bool
        return false unless upgrade = request.headers["Upgrade"]?
        return false unless upgrade.compare("websocket", case_insensitive: true) == 0

        request.headers.includes_word?("Connection", "Upgrade")
      end

      # HMR-клиент vite ходит на тот же origin (путь — обычно "/") с
      # подпротоколом vite-hmr: так отличаем его от чужих ws-роутов.
      private def vite_hmr?(request : HTTP::Request) : Bool
        request.headers.get?("Sec-WebSocket-Protocol").try(&.any? do |value|
          value.split(',').any?(&.strip.==("vite-hmr"))
        end) || false
      end

      # --- HTTP -------------------------------------------------------------

      private def proxy_http(context : HTTP::Server::Context) : Nil
        request = context.request
        headers = request.headers.clone
        host_header = "#{@host}:#{@port}"
        # forward_to_vite_dev_server гема: Host → vite, остальное —
        # X-Forwarded-* (Origin/Cookie/Referer идут как есть).
        headers["X-Forwarded-Host"] = headers["Host"]? || ""
        headers["X-Forwarded-Proto"] = "http"
        headers["X-Forwarded-Server"] = host_header
        headers["X-Forwarded-Port"] = @port.to_s
        headers["Host"] = host_header

        client = HTTP::Client.new(@host, @port)
        begin
          response = client.exec(request.method, request.resource,
            headers: headers, body: request.body)
          resp = context.response
          resp.status_code = response.status_code
          copy_headers(response.headers, resp.headers)
          if body_io = response.body_io?
            IO.copy(body_io, resp)
          else
            resp.print response.body? || ""
          end
        ensure
          client.close
        end
      end

      private def copy_headers(from : HTTP::Headers, to : HTTP::Headers) : Nil
        from.each do |name, values|
          # hop-by-hop и длину тела пересчитывает принимающая сторона
          next if {"Transfer-Encoding", "Content-Length", "Connection"}.includes?(name)
          to[name] = values
        end
      end

      # --- WebSocket (HMR) ----------------------------------------------------

      private def proxy_websocket(context : HTTP::Server::Context) : Nil
        request = context.request
        socket = TCPSocket.new(@host, @port)
        begin
          # Handshake: исходный запрос как есть (Sec-WebSocket-Key/
          # Protocol/Version, Origin), Host переписан на vite.
          request.headers["Host"] = "#{@host}:#{@port}"
          request.to_io(socket)
          socket.flush

          status, headers, preface = read_handshake(socket)
          response = context.response
          if status == 101
            response.status_code = 101
            copy_headers(headers, response.headers)
            response.headers["Connection"] = "Upgrade"
            response.upgrade do |io|
              io.write(preface) unless preface.empty?
              finished = Channel(Nil).new
              # IO.copy не флашит буферизованный io — крошечные ws-фреймы
              # застряли бы в буфере, поэтому копируем чанками с flush.
              spawn do
                buffer = Bytes.new(8192)
                loop do
                  length = socket.read(buffer)
                  break if length == 0
                  io.write(buffer[0, length])
                  io.flush
                end
                finished.send(nil)
              end
              spawn do
                buffer = Bytes.new(8192)
                loop do
                  length = io.read(buffer)
                  break if length == 0
                  socket.write(buffer[0, length])
                  socket.flush
                end
                finished.send(nil)
              end
              2.times { finished.receive }
              socket.close
            end
          else
            # vite отклонил handshake (не 101) — отдаём его ответ как есть
            socket.close
            response.status_code = status
            copy_headers(headers, response.headers)
          end
        rescue ex : Socket::Error | IO::Error
          socket.close rescue nil
          raise ex
        end
      end

      # Читает handshake-ответ vite байт-за-байтом до CRLFCRLF (чтобы не
      # забрать в буфер первые ws-фреймы) и возвращает статус, заголовки
      # и случайно прочитанные байты после заголовков.
      private def read_handshake(socket : IO) : {Int32, HTTP::Headers, Bytes}
        head = IO::Memory.new
        loop do
          byte = socket.read_byte
          raise IO::EOFError.new("vite closed handshake") unless byte
          head.write_byte(byte)
          break if head.to_s.ends_with?("\r\n\r\n")
        end
        lines = head.to_s.split("\r\n")
        status = lines.first.split(' ')[1]?.try(&.to_i?) ||
                 raise(IO::EOFError.new("bad status line from vite"))
        headers = HTTP::Headers.new
        lines.skip(1).each do |line|
          next if line.empty?
          name, _, value = line.partition(':')
          headers.add(name.strip, value.strip)
        end
        {status, headers, Bytes.empty}
      end
    end
  end
end
