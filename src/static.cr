# CRails::Middleware::Static — порт ActionDispatch::Static 8.1.4
# (lib/action_dispatch/middleware/static.rb).
#
# Oracle: oracle/static_cases.rb → oracle/static_expected.yml (14 кейсов
# с настоящего actionpack 8.1.4), зеркало — spec/static_spec.cr.
#
# Семантика 1:1:
# - только GET/HEAD, остальное — сквозь в приложение;
# - кандидаты: path, path.html, path/index.html (последние два — для
#   путей без известного расширения);
# - Content-Type по расширению (Rack::Mime-таблица: .js →
#   text/javascript и т.д.), неизвестное расширение → text/plain;
# - прекомпрессия: для сжимаемых типов (text/*, application/javascript,
#   image/svg+xml) ищутся path.br/path.gz; отдаётся по Accept-Encoding,
#   с Content-Encoding и Vary: accept-encoding (Vary ставится и при
#   identity, если .br/.gz соседи есть — как в геме);
# - path traversal ("..") блокируется (сквозь в приложение);
# - HEAD — 200 с заголовками и пустым телом;
# - CRails-дефолт (не в геме): /javascripts/* отдаётся из app/javascript
#   (пиннутые importmap-модули, см. importmap.cr) — заменой asset
#   pipeline; /vite/assets/* — из public (vite build);
#   /assets/* — порт Propshaft::Server (propshaft 1.3.2): digest
#   стриппится из URL (-[0-9a-zA-Z]{7,128} перед расширением), файл
#   ищется по logical path в подкаталогах app/assets/* (load path как
#   в propshaft railtie), отдаётся с Cache-Control immutable и ETag;
#   нерезолвированное — 404 text/plain "Not found" (как Propshaft::
#   Server, не сквозь в приложение).
#
# Задокументированные отклонения от гема:
# - Range-запросы (Rack::Files slice) — P2;
# - Last-Modified/ETag условные запросы — P2 (304-семантика);
# - CRails-дефолт (не в геме): под /vite/assets/ отдаётся
#   Cache-Control: public, max-age=31536000, immutable — имена файлов
#   хешированы `vite build`, crails заменяет Thruster/CDN.

require "digest/sha1"

module CRails
  module Middleware
    class Static
      include HTTP::Handler

      MIME = {
        ".html" => "text/html", ".css" => "text/css",
        ".js"   => "text/javascript", ".mjs" => "text/javascript",
        ".json" => "application/json", ".png" => "image/png",
        ".jpg"  => "image/jpeg", ".jpeg" => "image/jpeg",
        ".gif"  => "image/gif", ".svg" => "image/svg+xml",
        ".webp" => "image/webp", ".ico" => "image/vnd.microsoft.icon",
        ".txt"  => "text/plain", ".xml" => "application/xml",
        ".woff" => "font/woff", ".woff2" => "font/woff2",
        ".ttf"  => "font/ttf", ".otf" => "font/otf",
        ".wasm" => "application/wasm", ".map" => "application/json",
        ".mp4"  => "video/mp4", ".webm" => "video/webm",
        ".pdf"  => "application/pdf",
      } of String => String

      def initialize(@root : String = "public",
                     @headers : Hash(String, String) = {} of String => String,
                     @vite_immutable : Bool = true,
                     @javascripts_root : String = "app/javascript",
                     @assets_root : String = "app/assets")
        # Кэш тел файлов (public/ и /assets/*): замер wrk-ом показал ~2x
        # разрыв между отдачей с диска (File.open + IO.copy на каждый
        # запрос, 34k RPS на 64KB) и из памяти (75k RPS у голого
        # HTTP::Server). Ревалидация — stat по mtime+size, так что
        # правка файла подхватывается без рестарта.
        #
        # MT-предупреждение: кэш без блокировки — Crystal без
        # -Dpreview_mt однопоточно-кооперативен, переключение фибер
        # внутри Hash-операций не происходит. С preview_mt нужен Mutex.
        @body_cache = {} of String => CachedFile
      end

      # Лимиты кэша: файлы до 2MB и не более 4096 записей (при
      # переполнении кэш сбрасывается целиком — грубо, но bounded).
      CACHE_MAX_FILE_BYTES = 2 * 1024 * 1024
      CACHE_MAX_ENTRIES    = 4096

      private class CachedFile
        def initialize(@mtime : Time, @size : Int64, @body : String, @etag : String)
        end

        getter mtime : Time
        getter size : Int64
        getter body : String
        getter etag : String
      end

      # Возвращает закэшированное тело файла или читает+кэширует.
      # nil — файл исчез или больше лимита (caller откатывается на
      # стриминг с диска).
      private def read_cached(disk_path : String) : CachedFile?
        info = File.info?(disk_path)
        return nil unless info
        if (cached = @body_cache[disk_path]?) &&
           cached.mtime == info.modification_time && cached.size == info.size
          return cached
        end
        return nil if info.size > CACHE_MAX_FILE_BYTES
        body = File.read(disk_path)
        entry = CachedFile.new(info.modification_time, info.size, body,
          Digest::SHA1.hexdigest(body)[0, 8])
        @body_cache.clear if @body_cache.size >= CACHE_MAX_ENTRIES
        @body_cache[disk_path] = entry
        entry
      end

      def call(context : HTTP::Server::Context) : Nil
        if {"GET", "HEAD"}.includes?(context.request.method) && attempt(context)
          return
        end
        call_next(context)
      end

      private def attempt(context : HTTP::Server::Context) : Bool
        path = context.request.path.chomp('/')
        return false unless cleaned = clean_path(path)
        accept_encoding = context.request.headers["Accept-Encoding"]? || ""

        each_candidate(cleaned) do |filepath, content_type|
          next unless File.file?(full(filepath))
          serve(context, filepath, content_type, accept_encoding)
          return true
        end

        # CRails-расширение: /assets/* — propshaft-резолвинг (замена
        # asset pipeline). Активен только при существующем assets root.
        if cleaned.starts_with?("/assets/") && Dir.exists?(@assets_root)
          if (asset = resolve_propshaft_asset(cleaned))
            serve_asset(context, asset, accept_encoding)
          else
            not_found_asset(context)
          end
          return true
        end

        false
      end

      private def serve(context, filepath : String, content_type : String,
                        accept_encoding : String) : Nil
        response = context.response
        response.status_code = 200
        response.headers["Content-Type"] = content_type
        @headers.each { |k, v| response.headers[k] = v }

        body_file = filepath
        if compressible?(content_type)
          if (br = "#{filepath}.br"; File.file?(full(br)))
            response.headers["Vary"] = "accept-encoding"
            if accepts?(accept_encoding, "br")
              response.headers["Content-Encoding"] = "br"
              body_file = br
            end
          end
          if !response.headers["Content-Encoding"]? &&
             (gz = "#{filepath}.gz"; File.file?(full(gz)))
            response.headers["Vary"] = "accept-encoding"
            if accepts?(accept_encoding, "gzip")
              response.headers["Content-Encoding"] = "gzip"
              body_file = gz
            end
          end
        end

        # CRails-дефолт: хешированные vite-ассеты кэшируются навсегда.
        if @vite_immutable && !@headers.has_key?("Cache-Control") &&
           filepath.starts_with?("/vite/assets/")
          response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        end

        if context.request.method == "HEAD"
          response.headers["Content-Length"] =
            File.info?(full(body_file)).try(&.size).to_s
          return
        end
        if (cached = read_cached(full(body_file)))
          response.headers["Content-Length"] = cached.size.to_s
          response.print cached.body
        else
          # Большие файлы (видео и пр.) стримятся с диска, как Rack::Files.
          File.open(full(body_file)) do |file|
            response.headers["Content-Length"] = file.size.to_s
            IO.copy(file, response)
          end
        end
      end

      # --- CRails-расширение: propshaft-резолвинг /assets/* ---------------

      private struct PropshaftAsset
        def initialize(@body : String, @content_type : String, @etag : String)
        end

        getter body : String          # скомпилированный контент (propshaft)
        getter content_type : String
        getter etag : String          # digest ассета (8 hex, как SHA1[0,8])
      end

      # Load path как в propshaft railtie: каждый подкаталог assets root
      # добавляет свои файлы по пути относительно себя (первенство —
      # алфавитный порядок каталогов). Компиляторы — дефолты гема, так
      # что dev отдаёт compiled_content (url()-rewrite) байт-одинаково
      # с precompiled-выходом (паритет dev/prod).
      @propshaft_assembly : Propshaft::Assembly?

      private def propshaft_assembly : Propshaft::Assembly
        @propshaft_assembly ||= begin
          dirs = Dir.glob(File.join(@assets_root, "*")).sort.select { |d| Dir.exists?(d) }
          config = Propshaft::Config.new
          config.paths = dirs
          config.version = "1"
          Propshaft::Assembly.new(config)
        end
      end

      # Propshaft::Asset.extract_path_and_digest: digest — это
      # -[0-9a-zA-Z]{7,128} перед финальным расширением; из logical path
      # он вырезается, затем логический путь ищется в load path.
      # (CRails-отклонение от Propshaft::Server: устаревший digest в URL
      # не даёт 404 — отдаётся свежий файл.)
      private def resolve_propshaft_asset(path : String) : PropshaftAsset?
        logical = path.lchop("/assets/").sub(/\A(.*)-([0-9a-zA-Z]{7,128})(\.[^.]+)\z/) { "#{$1}#{$3}" }
        asset = propshaft_assembly.load_path.find(logical)
        return nil unless asset
        ext = File.extname(logical)
        PropshaftAsset.new(asset.compiled_content,
          MIME[ext]? || "text/plain", asset.digest)
      end

      # Propshaft::Server: Cache-Control immutable + ETag; charset=utf-8
      # для text/html и text/css (CONTENT_TYPES_WITH_UTF8_CHARSET).
      private def serve_asset(context, asset : PropshaftAsset,
                              accept_encoding : String) : Nil
        response = context.response
        response.status_code = 200
        content_type = asset.content_type
        if content_type.starts_with?("text/html") || content_type.starts_with?("text/css")
          content_type = "#{content_type}; charset=utf-8"
        end
        response.headers["Content-Type"] = content_type
        response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        response.headers["ETag"] = "\"#{asset.etag}\""
        response.headers["Vary"] = "Accept-Encoding"
        @headers.each { |k, v| response.headers[k] = v }

        response.headers["Content-Length"] = asset.body.bytesize.to_s
        return if context.request.method == "HEAD"
        response.print asset.body
      end

      private def not_found_asset(context) : Nil
        response = context.response
        response.status_code = 404
        response.headers["Content-Type"] = "text/plain"
        response.headers["Content-Length"] = "9"
        response.print "Not found"
      end

      private def each_candidate(path : String, &) : Nil
        ext = File.extname(path)
        content_type = MIME[ext]?
        yield path, content_type || "text/plain"
        # .html и /index.html — только для путей без известного расширения
        return if content_type
        yield "#{path}.html", "text/html"
        yield "#{path}/index.html", "text/html"
      end

      private def compressible?(content_type : String) : Bool
        content_type.starts_with?("text/") ||
          content_type.starts_with?("application/javascript") ||
          content_type == "image/svg+xml"
      end

      private def accepts?(accept_encoding : String, encoding : String) : Bool
        accept_encoding.split(',').any? { |e| e.strip.split(';').first.try(&.downcase) == encoding }
      end

      private def full(filepath : String) : String
        # /javascripts/* — из app/javascript (аналог asset pipeline:
        # importmap-хелперы пиннят модули в /javascripts/<path>).
        if filepath.starts_with?("/javascripts/")
          File.join(@javascripts_root, filepath.lchop("/javascripts"))
        else
          File.join(@root, filepath)
        end
      end

      # unescape + защита от traversal; nil — отдать запрос приложению.
      private def clean_path(path : String) : String?
        return "" if path.empty?
        decoded = URI.decode(path)
        return nil if decoded.includes?('\0')
        return nil if decoded.split('/').includes?("..")
        decoded
      end
    end
  end
end
