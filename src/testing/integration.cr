# ActionDispatch::Integration / IntegrationTest — analog of Rails'
# ActionDispatch::Testing::Integration (actionpack 8.1.4) on the CRails
# stack: in-process requests through the full middleware chain
# (`Application#call` over IO::Memory — no socket, no spawned server),
# with a cookie jar so session / flash / CSRF tokens survive across
# requests, automatic redirect following (up to 10 hops, POST→GET on
# 301/302/303 like Rails) and minitest-style response assertions.
#
# Deliberate deviations from Rails (documented, P1):
#   * no `xml_http_request` / `xhr` alias;
#   * no multipart file uploads;
#   * session/flash are not directly introspectable (cookie store,
#     controller-side in CRails) — assert them through response bodies.
#
# Usage in a spec:
#
#   app = CRails::Application.new.tap do |a|
#     a.routes.draw { get "/show", to: "demo#show" }
#   end
#   session = ActionDispatch::IntegrationSession.new(app)
#   session.get("/show")
#   session.response.not_nil!.body.should eq "show ok"

module ActionDispatch
  # Assertion failure — raised by assert_response/assert_redirected_to,
  # fails the enclosing `it` block with the message (minitest analog).
  class Assertion < Exception
  end

  # A parsed response of the last performed request. Parsed from the
  # serialized HTTP::Server::Response (headers + body), so multi-value
  # Set-Cookie survives intact.
  class TestResponse
    attr_reader status_code : Int32
    attr_reader headers : HTTP::Headers
    attr_reader body : String

    def initialize(@status_code : Int32, @headers : HTTP::Headers, @body : String)
    end

    def content_type : String?
      @headers["Content-Type"]?
    end

    def location : String?
      @headers["Location"]?
    end

    def success? : Bool
      (200..299).covers?(@status_code)
    end

    def redirect? : Bool
      (300..399).covers?(@status_code)
    end

    def missing? : Bool
      @status_code == 404
    end

    def error? : Bool
      (500..599).covers?(@status_code)
    end

    # Serialize the server response for this context. `io` must be the
    # same IO the response was constructed with (caller keeps the
    # reference); response.close flushes status/headers/body into it.
    def self.build(io : IO::Memory, response : HTTP::Server::Response) : self
      response.close unless response.closed?
      io.rewind
      parsed = HTTP::Client::Response.from_io(io, decompress: false)
      new(parsed.status_code, parsed.headers, parsed.body? || "")
    end
  end

  # Drives a CRails::Application in-process, keeping cookies between
  # requests (the "browser" half of Rails' Integration::Session; the
  # controller half is CRails' own middleware chain + Dispatcher).
  class IntegrationSession
    # Nested form params: {"post" => {"title" => "T1"}} flattens to
    # post[title]=T1 like Rails/Rack's nested param encoding.
    alias ParamValue = String | Hash(String, ParamValue)

    attr_reader response : TestResponse?
    # Path (with query string) of the last performed request — after
    # redirect following this is the *final* destination, like Rails'
    # IntegrationTest `request.path`.
    attr_reader path : String?
    # Default "example.test": dev-mode HostAuthorization allows one
    # subdomain label under .test/.localhost (Rails' www.example.com
    # needs the empty test-env hosts list; same semantics, host never
    # reaches transcripts).
    attr_accessor host : String = "example.test"
    # Rails' Integration::Session does not follow redirects by default
    # (IntegrationTest asserts on the 302; follow_redirect! follows
    # manually). Capybara-style drivers flip this to true.
    property? follow_redirects : Bool = false
    attr_accessor redirect_limit : Int32 = 10

    @cookies = {} of String => String
    @redirect_count : Int32 = 0

    def initialize(@app : CRails::Application)
    end

    {% for meth in %w(get post put patch delete head) %}
      def {{meth.id}}(path : String, params : Hash(String, ParamValue)? = nil,
                      headers : Hash(String, String)? = nil,
                      json : String? = nil) : TestResponse
        process({{meth.upcase}}, path, params, headers, json)
      end
    {% end %}

    # Cookies currently in the jar (post-absorption of the last
    # response's Set-Cookie headers).
    def cookies : Hash(String, String)
      @cookies
    end

    # Follow the redirect of the current response manually (when
    # follow_redirects? is false). Raises when there is nothing to follow.
    def follow_redirect! : TestResponse
      resp = @response.not_nil!
      unless resp.redirect?
        raise Assertion.new("Expected a redirect, got #{resp.status_code}")
      end
      location = resp.location.not_nil!
      perform_request("GET", location_to_path(location), nil, nil, nil).tap do |final|
        @response = final
      end
    end

    # --- minitest-style assertions --------------------------------------

    # assert_response :success / :redirect / :missing / :error /
    # :created / :no_content / :bad_request / :unauthorized / :forbidden
    def assert_response(kind : Symbol) : Nil
      resp = @response || raise Assertion.new("No request performed yet")
      ok = case kind
           when :success    then resp.success?
           when :redirect   then resp.redirect?
           when :missing    then resp.missing?
           when :error      then resp.error?
           when :created    then resp.status_code == 201
           when :no_content then resp.status_code == 204
           when :bad_request then resp.status_code == 400
           when :unauthorized then resp.status_code == 401
           when :forbidden  then resp.status_code == 403
           else
             raise Assertion.new("Unknown response kind: #{kind}")
           end
      unless ok
        raise Assertion.new("Expected response #{kind}, got #{resp.status_code}")
      end
    end

    def assert_redirected_to(expected_path : String) : Nil
      resp = @response || raise Assertion.new("No request performed yet")
      unless resp.redirect?
        raise Assertion.new("Expected a redirect, got #{resp.status_code}")
      end
      actual = location_to_path(resp.location.to_s)
      unless actual == expected_path
        raise Assertion.new("Expected redirect to #{expected_path}, got #{actual}")
      end
    end

    # --- internals --------------------------------------------------------

    def process(method : String, path : String,
                params : Hash(String, ParamValue)? = nil,
                headers : Hash(String, String)? = nil,
                json : String? = nil) : TestResponse
      @redirect_count = 0
      @response = perform_request(method, path, params, headers, json)
      while follow_redirects? && @response.not_nil!.redirect?
        @redirect_count += 1
        if @redirect_count > @redirect_limit
          raise Assertion.new("Too many redirects (#{redirect_limit})")
        end
        resp = @response.not_nil!
        target = location_to_path(resp.location.not_nil!)
        if resp.status_code.in?(301, 302, 303)
          # Rails converts to GET and drops the body on these.
          @response = perform_request("GET", target, nil, headers, nil)
        else
          @response = perform_request(method, target, params, headers, json)
        end
      end
      @response.not_nil!
    end

    private def perform_request(method : String, path : String,
                                params : Hash(String, ParamValue)?,
                                headers : Hash(String, String)?,
                                json : String?) : TestResponse
      h = HTTP::Headers.new
      headers.try &.each { |k, v| h[k] = v }
      h["Host"] = @host unless h["Host"]?

      body : String? = nil
      if json
        body = json
        h["Content-Type"] = "application/json" unless h["Content-Type"]?
      elsif params && !method.in?("GET", "HEAD", "DELETE")
        body = encode_params(params)
        h["Content-Type"] = "application/x-www-form-urlencoded" unless h["Content-Type"]?
      end

      target = path
      if params && method.in?("GET", "HEAD", "DELETE")
        query = encode_params(params)
        target = path.includes?('?') ? "#{path}&#{query}" : "#{path}?#{query}"
      end

      request = HTTP::Request.new(method, target, h, body)
      apply_cookies(request)

      io = IO::Memory.new
      server_response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, server_response)
      @app.call(context)
      result = TestResponse.build(io, server_response)
      absorb_cookies(result)
      @path = target
      result
    end

    # Absolute redirect targets (http://host/path) back to a path the
    # app can serve; relative locations pass through untouched.
    private def location_to_path(location : String) : String
      if location.starts_with?("http://") || location.starts_with?("https://")
        uri = URI.parse(location)
        path = uri.path.presence || "/"
        uri.query ? "#{path}?#{uri.query}" : path
      else
        location
      end
    end

    # {"post" => {"title" => "T1"}} -> post[title]=T1 (Rack's nested
    # form encoding; leaf order follows hash insertion order).
    private def encode_params(params : Hash(String, ParamValue)) : String
      pairs = [] of String
      walk_params(params) do |key, value|
        pairs << "#{URI.encode_www_form(key)}=#{URI.encode_www_form(value)}"
      end
      pairs.join("&")
    end

    private def walk_params(params : Hash(String, ParamValue), prefix : String? = nil, &block : String, String -> Nil) : Nil
      params.each do |key, value|
        full_key = prefix ? "#{prefix}[#{key}]" : key
        case value
        when String   then yield full_key, value
        when Hash     then walk_params(value, full_key) { |k, v| yield k, v }
        end
      end
    end

    private def apply_cookies(request : HTTP::Request) : Nil
      return if @cookies.empty?
      request.headers["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
    end

    private def absorb_cookies(resp : TestResponse) : Nil
      resp.headers.get?("Set-Cookie").try &.each do |cookie|
        next unless cookie.includes?('=')
        key, value = cookie.split('=', 2)
        value = value.split(';').first.to_s
        if value.empty?
          @cookies.delete(key)
        else
          @cookies[key] = value
        end
      end
    end
  end

  # Include-able Rails-style facade: `integration_app = APP` once, then
  # get/post/follow_redirects/assert_response read like an
  # ActionDispatch::IntegrationTest instance.
  module IntegrationTest
    @integration : IntegrationSession?
    @integration_app : CRails::Application?

    protected def integration_app=(app : CRails::Application) : Nil
      @integration_app = app
      @integration = nil
    end

    def integration : IntegrationSession
      @integration ||= IntegrationSession.new(
        @integration_app || ::CRails.application)
    end

    {% for meth in %w(get post put patch delete head) %}
      def {{meth.id}}(path : String, params : Hash(String, ParamValue)? = nil,
                      headers : Hash(String, String)? = nil,
                      json : String? = nil) : TestResponse
        integration.{{meth.id}}(path, params, headers, json)
      end
    {% end %}

    def response : TestResponse
      integration.response.not_nil!
    end

    def assert_response(kind : Symbol) : Nil
      integration.assert_response(kind)
    end

    def assert_redirected_to(path : String) : Nil
      integration.assert_redirected_to(path)
    end

    def follow_redirect! : TestResponse
      integration.follow_redirect!
    end
  end
end
