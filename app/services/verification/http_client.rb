require "net/http"

module Verification
  # The only way CertTrack talks to issuers' sites (docs/PLAN.md, Phase 3b, "Automatic check rules").
  #
  #   client = Verification::HttpClient.new
  #   response = client.get("https://www.oshacardportal.com/portalapp/verify/ABC123")
  #   response = client.post("https://ecards.heart.org/Student/MyeCards/VerifyECards", form: { "codes" => "123" })
  #   response.status # => 200;  response.body # => "<html>..."  (at most 1 MB);  response.uri # => the final URI
  #
  # Rules: HTTPS on port 443 only, and only to hosts on the domains of active issuers that have a
  # network automatic check (Verification::Checkers::NETWORK_KEYS). Redirects are followed (at most
  # Config.max_redirects) only while they stay on those hosts. Each request takes at most
  # Config.http_timeout seconds and Config.max_response_bytes. At most one request to a host every
  # Config.min_request_interval seconds (counted per call, so a redirect on the same host doesn't
  # trip it) and Config.daily_requests_per_host a day (every hop counts), kept in Rails.cache.
  # Over a limit, the request isn't sent and Throttled or DailyLimit is raised: it never sleeps.
  # The user agent names CertTrack (Config.user_agent); no cookies are kept.
  #
  # Every failure raises a HttpClient::Error whose message is a plain sentence for the
  # authenticity note (it names the host, never the code) and whose reason is a short word for
  # the result's details.
  #
  # Tests never reach the network: the test environment's default transport raises. Inject one:
  #   Verification::HttpClient.with(transport: ->(method, uri, headers, body) { Response.new(...) }) { ... }
  #   Verification::HttpClient.new(transport: fake, cache: ActiveSupport::Cache::MemoryStore.new)
  class HttpClient
    Response = Data.define(:status, :headers, :body, :uri) do
      def initialize(status:, body: "", headers: {}, uri: nil)
        super(status: status.to_i, headers: headers.to_h.transform_keys { |key| key.to_s.downcase }, body: body.to_s, uri: uri)
      end

      def success? = status.between?(200, 299)
      def redirect? = [ 301, 302, 303, 307, 308 ].include?(status)
    end

    class Error < StandardError
      def reason = "error"
    end

    # Not HTTPS, not an allowed host, or a redirect away from the allowed hosts.
    class Refused < Error
      def reason = "refused"
    end

    # This host was asked less than Config.min_request_interval seconds ago; try again shortly.
    class Throttled < Error
      def reason = "busy"
    end

    # This host has had Config.daily_requests_per_host requests today.
    class DailyLimit < Error
      def reason = "daily_limit"
    end

    class TimedOut < Error
      def reason = "timeout"
    end

    class TooLarge < Error
      def reason = "too_large"
    end

    # Couldn't connect, TLS failed, or the connection broke.
    class Failed < Error
      def reason = "unreachable"
    end

    # The test environment's transport: tests must inject one (no real network in tests, ever).
    class NetworkDisabled < StandardError; end

    REDIRECT_KEEPS_METHOD = [ 307, 308 ].freeze
    CACHE_PREFIX = "verification/http".freeze
    OVERRIDES_KEY = :verification_http_client_overrides
    private_constant :OVERRIDES_KEY

    # Sends requests with Net::HTTP. #call(method, uri, headers, body) -> Response; stops reading
    # past max_bytes (TooLarge) and gives up at the deadline (TimedOut). The deadline covers the
    # whole request, connecting and the status line and headers included: Net::HTTP's own
    # timeouts are per read, so a server sending headers a byte at a time (or without end) would
    # otherwise hold the worker thread past it.
    class NetHttpTransport
      def initialize(timeout:, max_bytes:)
        @timeout = timeout
        @max_bytes = max_bytes
      end

      def call(method, uri, headers, body)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        Timeout.timeout(@timeout) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
            open_timeout: @timeout, read_timeout: @timeout, write_timeout: @timeout, ssl_timeout: @timeout) do |http|
            request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri.request_uri, headers)
            request.body = body if body
            http.request(request) do |response|
              raise TooLarge, too_large_message(uri) if response["content-length"].to_i > @max_bytes

              return Response.new(status: response.code, headers: response.each_header.to_h,
                body: read_body(response, uri, deadline), uri: uri)
            end
          end
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
        raise TimedOut, "#{uri.host} didn't answer within #{@timeout} seconds."
      rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, EOFError, IOError
        raise Failed, "#{uri.host} couldn't be reached."
      end

      private
        def read_body(response, uri, deadline)
          body = +""
          response.read_body do |chunk|
            body << chunk
            raise TooLarge, too_large_message(uri) if body.bytesize > @max_bytes
            raise TimedOut, "#{uri.host} didn't answer within #{@timeout} seconds." if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          end
          body
        end

        def too_large_message(uri)
          "#{uri.host} sent a page larger than #{@max_bytes / 1.megabyte} MB."
        end
    end

    class << self
      # The transport new clients use: an override from .with, else Net::HTTP (raises in tests).
      def transport
        overrides.fetch(:transport) do
          if Rails.env.test?
            ->(*) { raise NetworkDisabled, "Tests may not reach issuers' sites: use Verification::HttpClient.with(transport: ...)" }
          else
            NetHttpTransport.new(timeout: Config.http_timeout, max_bytes: Config.max_response_bytes)
          end
        end
      end

      # Where the request counts are kept: an override from .with, else Rails.cache.
      def cache
        overrides.fetch(:cache) { Rails.cache }
      end

      # Runs the block with transport: and/or cache: replaced, for this thread or fiber only.
      def with(**values)
        unknown = values.keys - %i[transport cache]
        raise ArgumentError, "unknown Verification::HttpClient settings: #{unknown.join(", ")}" if unknown.any?

        previous = overrides
        ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] = previous.merge(values)
        begin
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] = previous
        end
      end

      # Registrable domains requests may go to: those of active issuers with a network check.
      def allowed_domains
        CertificateIssuer.active.where(automatic_check: Checkers::NETWORK_KEYS).pluck(:domains).flatten.uniq
      end

      private
        def overrides
          ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] || {}
        end
    end

    def initialize(transport: self.class.transport, cache: self.class.cache, allowed_domains: nil)
      @transport = transport
      @cache = cache
      @allowed_domains = allowed_domains
    end

    def get(url, headers: {})
      request(:get, url, headers: headers)
    end

    # form: a Hash sent as application/x-www-form-urlencoded.
    def post(url, form:, headers: {})
      request(:post, url, headers: headers.merge("Content-Type" => "application/x-www-form-urlencoded"),
        body: URI.encode_www_form(form))
    end

    private
      def request(method, url, headers:, body: nil)
        uri = checked_uri(url)
        reserve_interval!(uri.host)
        headers = default_headers.merge(headers)

        (Config.max_redirects + 1).times do
          count_today!(uri.host)
          response = @transport.call(method, uri, headers, body)
          check_size!(response, uri)
          return response.with(uri: uri) unless response.redirect?

          uri = redirect_uri(uri, response)
          unless REDIRECT_KEEPS_METHOD.include?(response.status)
            method = :get
            body = nil
            headers = headers.except("Content-Type")
          end
        end
        raise Refused, "#{uri.host} redirected the check more than #{Config.max_redirects} times."
      end

      def default_headers
        { "User-Agent" => Config.user_agent, "Accept" => "text/html,application/xhtml+xml" }
      end

      # The URI for url when it may be asked: HTTPS, port 443, host on an allowed domain.
      def checked_uri(url, from: nil)
        uri = URI.parse(url.to_s.strip)
        host = uri.host.to_s.downcase
        if uri.scheme&.downcase != "https" || uri.port != 443 || host.blank? || uri.userinfo.present?
          raise Refused, from ? "#{from} redirected the check to an address that isn't HTTPS." : "Only HTTPS addresses are checked."
        end
        unless allowed_domains.include?(CertificateIssuer.registrable_domain(host))
          raise Refused, from ? "#{from} redirected the check to #{host}, which CertTrack doesn't contact." :
            "#{host} isn't an issuer site CertTrack checks automatically."
        end
        uri
      rescue URI::InvalidURIError
        raise Refused, from ? "#{from} redirected the check to an address that can't be read." : "The address can't be read."
      end

      def redirect_uri(uri, response)
        location = response.headers["location"].to_s.strip
        raise Failed, "#{uri.host} redirected the check without saying where." if location.blank?

        checked_uri(uri.merge(location).to_s, from: uri.host)
      rescue URI::InvalidURIError
        raise Refused, "#{uri.host} redirected the check to an address that can't be read."
      end

      def check_size!(response, uri)
        return if response.body.bytesize <= Config.max_response_bytes

        raise TooLarge, "#{uri.host} sent a page larger than #{Config.max_response_bytes / 1.megabyte} MB."
      end

      def allowed_domains
        @allowed_domains ||= self.class.allowed_domains
      end

      # One request per host per interval: the first writer of the key wins until it expires.
      def reserve_interval!(host)
        interval = Config.min_request_interval
        return if @cache.write("#{CACHE_PREFIX}/#{host}/recent", true, expires_in: interval.seconds, unless_exist: true)

        raise Throttled, "#{host} was asked moments ago; CertTrack waits #{interval} seconds between checks with one site."
      end

      def count_today!(host)
        count = @cache.increment("#{CACHE_PREFIX}/#{host}/#{Date.current.iso8601}", 1, expires_in: 2.days)
        return if count.nil? || count <= Config.daily_requests_per_host

        raise DailyLimit, "#{host} has had today's #{Config.daily_requests_per_host} automatic checks."
      end
  end
end
