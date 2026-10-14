# CRails::Middleware::HostAuthorization — port of
# ActionDispatch::HostAuthorization (Rails 8.1.4): guards from DNS
# rebinding attacks by explicitly permitting the hosts a request can be
# sent to. Oracle: oracle/host_authorization_expected.yml (captured from
# a real 8.1.4 app, oracle/host_authorization_cases.rb); mirrored in
# spec/host_authorization_spec.cr.
#
# Deviations from the gem (asserted in the spec footer):
# - the middleware is always in the default stack (CRails composes the
#   chain before environments/*.cr run, so config.hosts is read at call
#   time); with empty hosts it is a no-op — Rails skips inserting it
#   entirely, observable only via `crails middleware` listing;
# - config.host_authorization = {exclude:, response_app:} becomes two
#   typed properties (config.host_authorization_exclude /
#   _response_app); the response app is a Proc(HTTP::Server::Context,
#   Nil) writing the response instead of a Rack triple;
# - the debug body (consider_all_requests_local) renders the same
#   textual content as the gem's rescues/blocked_host template without
#   the full DebugView chrome (no CSS/JS rescue layout);
# - IPAddr entries are CRails::Middleware::IPCidr (v4/v6 CIDR strings).

require "./middleware"

module CRails
  module Middleware
    # One entry of config.hosts: an exact/subdomain hostname String, a
    # Regex (used verbatim — the gem quirk of never allowing a port on
    # a fully anchored pattern is preserved), or an IPCidr.
    alias HostEntry = String | Regex | IPCidr

    # IPAddr("a.b.c.d/p") port (v4 + v6, "::" compression supported;
    # no embedded-IPv4 forms like "::ffff:1.2.3.4").
    class IPCidr
      getter masked : UInt128
      getter prefix : Int32
      getter? ipv6 : Bool

      def initialize(cidr : String)
        base, _, prefix_text = cidr.partition("/")
        @ipv6 = base.includes?(":")
        total = @ipv6 ? 128 : 32
        @prefix = prefix_text.empty? ? total : prefix_text.to_i
        if @prefix < 0 || @prefix > total
          raise ArgumentError.new("invalid prefix in #{cidr}")
        end
        value = IPCidr.parse?(base)
        unless value
          raise ArgumentError.new("invalid address in #{cidr}")
        end
        @masked = value & IPCidr.mask(@prefix, total)
      end

      def includes?(host : String) : Bool
        value = IPCidr.parse?(host)
        # family mismatch or non-IP hostname: blocked (the gem rescues
        # the IPAddr::Error and returns false).
        return false unless value && host.includes?(":") == @ipv6
        (value & IPCidr.mask(@prefix, @ipv6 ? 128 : 32)) == @masked
      end

      def ==(other : IPCidr) : Bool
        masked == other.masked && prefix == other.prefix && ipv6? == other.ipv6?
      end

      def hash(hasher)
        hasher = masked.hash(hasher)
        hasher = prefix.hash(hasher)
        ipv6?.hash(hasher)
      end

      def to_s(io : IO) : IO
        io << "IPCidr(" << masked << '/' << prefix << ')'
      end

      protected def self.mask(prefix : Int32, total : Int32) : UInt128
        return UInt128::MAX if prefix >= total
        (UInt128::MAX << (total - prefix)) & UInt128::MAX
      end

      # Parses a bare IP (no port, no brackets) into its integer value.
      protected def self.parse?(host : String) : UInt128?
        if host.includes?(":")
          parse_ipv6?(host)
        elsif host.matches?(/\A\d+\.\d+\.\d+\.\d+\z/)
          parts = host.split('.').map(&.to_u32)
          return nil if parts.any? { |p| p > 255 }
          (parts[0].to_u128 << 24) | (parts[1].to_u128 << 16) |
            (parts[2].to_u128 << 8) | parts[3].to_u128
        end
      end

      private def self.parse_ipv6?(host : String) : UInt128?
        return nil unless host.matches?(/\A[0-9a-fA-F:.]+\z/)
        parts = host.split("::")
        return nil if parts.size > 2
        if parts.size == 2
          left = parts[0].empty? ? [] of String : parts[0].split(':')
          right = parts[1].empty? ? [] of String : parts[1].split(':')
          missing = 8 - left.size - right.size
          return nil if missing < 0
          groups = left + Array.new(missing, "0") + right
        else
          groups = host.split(':')
          return nil unless groups.size == 8
        end
        return nil unless groups.size == 8
        value = UInt128.new(0)
        groups.each do |g|
          return nil unless g.matches?(/\A[0-9a-fA-F]{1,4}\z/)
          value = (value << 16) | g.to_u128(16)
        end
        value
      end
    end

    # ActionDispatch::HostAuthorization::Permissions port: compiles the
    # configured hosts into matchers (Strings → anchored case-insensitive
    # regexes with an optional port suffix, ".dot" entries additionally
    # allow one subdomain label; Regexp entries are wrapped with \A..\z
    # and an optional port suffix verbatim, like the gem).
    class Permissions
      @matchers : Array(HostEntry)

      def initialize(hosts : Enumerable(HostEntry))
        @matchers = hosts.map { |host| sanitize(host).as(HostEntry) }
      end

      def empty? : Bool
        @matchers.empty?
      end

      def allows?(host : String?) : Bool
        return false unless host
        @matchers.any? do |allowed|
          case allowed
          when IPCidr     then allowed.includes?(extract_hostname(host) || host)
          when Regex      then allowed.matches?(host)
          when String     then allowed == host
          else                 false
          end
        end
      end

      private def sanitize(host : HostEntry) : HostEntry
        case host
        when Regex  then Regex.new("\\A#{host.source}(?::\\d+)?\\z", host.options)
        when String then sanitize_string(host)
        else             host
        end
      end

      private def sanitize_string(host : String) : Regex
        port = "(?::\\d+)?" unless host.matches?(/:\d+\z/)
        if host.starts_with?(".")
          Regex.new("\\A(?:[a-z0-9-]+\\.)?#{Regex.escape(host[1..])}#{port}\\z", :ignore_case)
        else
          Regex.new("\\A#{Regex.escape(host)}#{port}\\z", :ignore_case)
        end
      end

      # host.slice(VALID_IP_HOSTNAME, "host") analog: pulls the IP part
      # out of a host-with-port (bracketed or bare), nil for hostnames.
      private def extract_hostname(host : String) : String?
        IPV4_HOSTNAME.match(host).try(&.["host"]) ||
          IPV6_HOSTNAME_WITH_PORT.match(host).try(&.["host"]) ||
          IPV6_HOSTNAME.match(host).try(&.["host"])
      end

      PORT_REGEX            = /(?::\d+)/
      SUBDOMAIN_REGEX       = /(?:[a-z0-9-]+\.)/i
      IPV4_HOSTNAME         = /\A(?<host>\d+\.\d+\.\d+\.\d+)(?::\d+)?\z/
      IPV6_HOSTNAME         = /\A(?<host>[a-f0-9]*:[a-f0-9.:]+)\z/i
      IPV6_HOSTNAME_WITH_PORT = /\A\[(?<host>[a-f0-9]*:[a-f0-9.:]+)\](?::\d+)?\z/i
    end

    # ActionDispatch::HostAuthorization port. Checks the Host header and
    # the last entry of X-Forwarded-Host against config.hosts; blocked
    # requests get the 403 response app (config.host_authorization_
    # response_app or the default one below).
    class HostAuthorization
      include HTTP::Handler
      include Configurable

      RESPONSE_STATUS = 403

      @cached_hosts : Array(HostEntry)?
      @cached_permissions : Permissions?

      def call(context : HTTP::Server::Context) : Nil
        permissions = self.permissions
        return call_next(context) if permissions.empty?

        blocked = blocked_hosts(context.request)
        if blocked.empty? || excluded?(context)
          call_next(context)
        elsif (custom_app = response_app)
          custom_app.call(context)
        else
          default_response(context, blocked)
        end
      end

      # config.hosts mutations (config/environments/*.cr run after the
      # stack is composed) are picked up: rebuild on content change.
      private def permissions : Permissions
        hosts = application.try(&.config.hosts) || [] of HostEntry
        if @cached_hosts != hosts
          @cached_permissions = Permissions.new(hosts)
          @cached_hosts = hosts.dup
        end
        @cached_permissions.not_nil!
      end

      private def blocked_hosts(request : HTTP::Request) : Array(String)
        blocked = [] of String

        origin_host = request.headers["Host"]?
        blocked << origin_host if origin_host && !permissions.allows?(origin_host)

        forwarded_host = request.headers["X-Forwarded-Host"]?
          .try(&.split(/,\s?/).last?)
        blocked << forwarded_host if forwarded_host &&
                                    !forwarded_host.blank? &&
                                    !permissions.allows?(forwarded_host)

        blocked
      end

      private def excluded?(context : HTTP::Server::Context) : Bool
        application.try(&.config.host_authorization_exclude).try(&.call(context)) || false
      end

      private def response_app : Proc(HTTP::Server::Context, Nil)?
        application.try(&.config.host_authorization_response_app)
      end

      # DefaultResponseApp port: logs the blocked hosts and responds
      # 403; the debug body renders only when requests are considered
      # local (development), like consider_all_requests_local.
      private def default_response(context : HTTP::Server::Context, blocked : Array(String)) : Nil
        request = context.request
        format = request.headers["X-Requested-With"]? == "XMLHttpRequest" ? "text/plain" : "text/html"

        CRails.logger.error { "[#{self.class.name}] Blocked hosts: #{blocked.join(", ")}" }

        body = response_body(blocked)
        response = context.response
        response.status_code = RESPONSE_STATUS
        response.headers["Content-Type"] = "#{format}; charset=UTF-8"
        response.headers["Content-Length"] = body.bytesize.to_s
        response.print body
      end

      private def response_body(blocked : Array(String)) : String
        return "" unless CRails.env.development?

        String.build do |io|
          io << "<!DOCTYPE html>\n<html>\n  <body>\n"
          io << "    <h1>Blocked hosts: #{HTML.escape(blocked.join(", "))}</h1>\n"
          io << "    <h2>To allow requests to these hosts, make sure they are valid hostnames (containing only numbers, letters, dashes and dots), then add the following to your environment configuration:</h2>\n"
          blocked.each do |host|
            io << %(    config.hosts &lt;&lt; "#{HTML.escape(host)}"\n)
          end
          io << "    <p>For more details on host authorization view: https://guides.rubyonrails.org/configuring.html#actiondispatch-hostauthorization</p>\n"
          io << "  </body>\n</html>\n"
        end
      end
    end
  end
end
