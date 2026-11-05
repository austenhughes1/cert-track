require "test_helper"
require_relative "verification_test_support"

class Verification::HttpClientTest < ActiveSupport::TestCase
  include VerificationTestSupport

  PORTAL = "https://www.oshacardportal.com/portalapp/verify/AB12CD34".freeze

  setup do
    seed_issuers
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  def client(transport)
    Verification::HttpClient.new(transport: transport, cache: @cache)
  end

  def transport(*replies)
    queue = replies.dup
    FakeTransport.new { queue.shift || raise("unexpected request") }
  end

  test "a GET to an issuer with a network check sends the user agent and returns the page" do
    fake = transport(response("<html>VALID</html>"))

    reply = client(fake).get(PORTAL)

    assert_equal 200, reply.status
    assert_equal "<html>VALID</html>", reply.body
    assert_equal PORTAL, reply.uri.to_s
    request = fake.requests.sole
    assert_equal :get, request[:method]
    assert_equal "CertTrack certificate verification (+https://certs.abaventures.net)", request[:headers]["User-Agent"]
    assert_nil request[:body]
  end

  test "a POST sends the form urlencoded" do
    fake = transport(response("ok"))

    client(fake).post("https://ecards.heart.org/Student/MyeCards/VerifyECards", form: { "codes" => "212345678901" })

    request = fake.requests.sole
    assert_equal [ :post, "codes=212345678901" ], [ request[:method], request[:body] ]
    assert_equal "application/x-www-form-urlencoded", request[:headers]["Content-Type"]
  end

  test "only HTTPS on port 443 is asked" do
    fake = transport

    [ "http://www.oshacardportal.com/portalapp/verify/A1", "https://www.oshacardportal.com:8443/portalapp/verify/A1",
      "ftp://www.oshacardportal.com/x", "https://user:pw@www.oshacardportal.com/x", "not a url" ].each do |url|
      error = assert_raises(Verification::HttpClient::Refused, url) { client(fake).get(url) }
      assert_equal "refused", error.reason
    end
    assert_empty fake.requests
  end

  test "only hosts of active issuers with a network check are asked" do
    fake = transport

    %w[https://www.redcross.org/take-a-class/qrcode?certnumber=T1 https://verify.360training.com/
       https://example.com/ https://redcross-verify.com/].each do |url|
      error = assert_raises(Verification::HttpClient::Refused, url) { client(fake).get(url) }
      assert_match "isn't an issuer site CertTrack checks automatically", error.message
    end

    issuer("OTIEC").update!(active: false)
    assert_raises(Verification::HttpClient::Refused) { client(fake).get(PORTAL) }
    assert_empty fake.requests
  end

  test "redirects are followed while they stay on allowed hosts; a 303 turns a POST into a GET" do
    fake = transport(
      response(status: 303, headers: { "Location" => "/Student/MyeCards/Results" }),
      response(status: 301, headers: { "Location" => "https://ecards.heart.org/Student/MyeCards/Results/" }),
      response("<table id='tblECards'></table>")
    )

    reply = client(fake).post("https://ecards.heart.org/Student/MyeCards/VerifyECards", form: { "codes" => "1" })

    assert_equal "https://ecards.heart.org/Student/MyeCards/Results/", reply.uri.to_s
    assert_equal [ :post, :get, :get ], fake.requests.map { _1[:method] }
    assert_nil fake.requests.last[:body]
    assert_nil fake.requests.last[:headers]["Content-Type"]
  end

  test "a 307 redirect keeps the method and body" do
    fake = transport(response(status: 307, headers: { "location" => "https://nationalcprfoundation.com/verify/result" }), response("ok"))

    client(fake).post("https://nationalcprfoundation.com/verify/", form: { "certificate_code" => "C1" })

    assert_equal [ :post, :post ], fake.requests.map { _1[:method] }
    assert_equal "certificate_code=C1", fake.requests.last[:body]
  end

  test "a redirect off the allowed hosts, or to http, is refused before it is followed" do
    [ "https://example.com/phish", "http://www.oshacardportal.com/portalapp/verify/A1", "https://redcross.org/" ].each do |location|
      fake = transport(response(status: 302, headers: { "location" => location }))

      error = assert_raises(Verification::HttpClient::Refused, location) { client(fake).get(PORTAL) }

      assert_match "www.oshacardportal.com redirected the check", error.message
      assert_equal 1, fake.requests.size, "the redirect target is never asked"
      @cache.clear
    end
  end

  test "too many redirects are refused" do
    loop_reply = response(status: 302, headers: { "location" => PORTAL })
    fake = FakeTransport.new { loop_reply }

    assert_raises(Verification::HttpClient::Refused) { client(fake).get(PORTAL) }
    assert_equal Verification::Config.max_redirects + 1, fake.requests.size
  end

  test "a page over 1 MB is refused" do
    fake = transport(response("x" * (1.megabyte + 1)))

    error = assert_raises(Verification::HttpClient::TooLarge) { client(fake).get(PORTAL) }
    assert_equal "too_large", error.reason
    assert_match "larger than 1 MB", error.message
  end

  test "one request per host every 5 seconds: a second one is not sent" do
    travel_to Time.zone.local(2026, 11, 4, 10, 0)
    fake = FakeTransport.new { response("ok") }

    client(fake).get(PORTAL)
    error = assert_raises(Verification::HttpClient::Throttled) { client(fake).get(PORTAL) }
    assert_equal "busy", error.reason
    assert_match "waits 5 seconds between checks", error.message
    assert_equal 1, fake.requests.size

    client(fake).get("https://www.nationaloshafoundation.com/certificate-verification/?certificate_id=1")
    assert_equal 2, fake.requests.size, "another host is not held up"

    travel 4.seconds
    assert_raises(Verification::HttpClient::Throttled) { client(fake).get(PORTAL) }
    travel 2.seconds
    client(fake).get(PORTAL)
    assert_equal 3, fake.requests.size
  end

  test "a redirect on the same host is part of the same request, not throttled" do
    fake = transport(response(status: 301, headers: { "location" => "#{PORTAL}/" }), response("ok"))

    assert_equal "ok", client(fake).get(PORTAL).body
    assert_equal 2, fake.requests.size
  end

  test "200 requests a day per host, then nothing until tomorrow" do
    travel_to Time.zone.local(2026, 11, 4, 10, 0)
    fake = FakeTransport.new { response("ok") }

    Verification::Config.with(daily_requests_per_host: 3) do
      3.times do
        client(fake).get(PORTAL)
        travel 6.seconds
      end
      error = assert_raises(Verification::HttpClient::DailyLimit) { client(fake).get(PORTAL) }
      assert_equal "daily_limit", error.reason
      assert_match "today's 3 automatic checks", error.message
      assert_equal 3, fake.requests.size

      travel 1.day
      client(fake).get(PORTAL)
    end
    assert_equal 4, fake.requests.size
  end

  test "the default limit is 200 a day" do
    travel_to Time.zone.local(2026, 11, 4, 10, 0)
    @cache.write("verification/http/www.oshacardportal.com/2026-11-04", 200)

    assert_raises(Verification::HttpClient::DailyLimit) { client(transport).get(PORTAL) }
  end

  test "transport errors pass through as HttpClient errors" do
    fake = FakeTransport.new { raise Verification::HttpClient::TimedOut, "www.oshacardportal.com didn't answer within 10 seconds." }

    error = assert_raises(Verification::HttpClient::TimedOut) { client(fake).get(PORTAL) }
    assert_equal "timeout", error.reason
  end

  test "the test environment's default transport refuses to reach the network" do
    Verification::HttpClient.with(cache: @cache) do
      assert_raises(Verification::HttpClient::NetworkDisabled) { Verification::HttpClient.new.get(PORTAL) }
    end
  end

  test "with sets the transport and cache for the block only" do
    fake = transport(response("ok"))

    Verification::HttpClient.with(transport: fake, cache: @cache) { Verification::HttpClient.new.get(PORTAL) }

    assert_equal 1, fake.requests.size
    assert_not_equal fake, Verification::HttpClient.transport
    assert_raises(ArgumentError) { Verification::HttpClient.with(proxy: "x") { flunk } }
  end

  test "allowed_domains are the domains of active issuers with a network check" do
    assert_equal %w[heart.org nationalcprfoundation.com nationaloshafoundation.com oshacardportal.com],
      Verification::HttpClient.allowed_domains.sort
  end

  test "the Net::HTTP transport is what runs outside tests" do
    transport = Verification::HttpClient::NetHttpTransport.new(timeout: 10, max_bytes: 1.megabyte)

    assert_respond_to transport, :call
  end

  # Net::HTTP is replaced, so nothing leaves the machine: a server that is slow to send its
  # status line and headers, where Net::HTTP's per-read timeouts never fire.
  test "the Net::HTTP transport's deadline covers the whole request, headers included" do
    slow_headers = Module.new do
      def start(*, **)
        40.times { sleep 0.05 } # each "read" succeeds, but the headers take 2 seconds
        nil
      end
    end
    Net::HTTP.singleton_class.prepend(slow_headers)
    transport = Verification::HttpClient::NetHttpTransport.new(timeout: 0.3, max_bytes: 1.megabyte)
    uri = URI("https://ecards.heart.org/Student/MyeCards")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Verification::HttpClient::TimedOut) { transport.call(:get, uri, {}, nil) }

    assert_equal "ecards.heart.org didn't answer within 0.3 seconds.", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
  ensure
    slow_headers&.send(:remove_method, :start)
  end
end
