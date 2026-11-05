# Helpers for the Verification tests: the default issuers, a fake transport that records every
# request (no test ever reaches a real site) and the crafted issuer pages in
# test/fixtures/files/verification/ (synthetic names only).
module VerificationTestSupport
  # Records requests and answers them with the block's Response (or raises what it raises).
  class FakeTransport
    attr_reader :requests

    def initialize(&responder)
      @responder = responder
      @requests = []
    end

    def call(method, uri, headers, body)
      @requests << { method: method, url: uri.to_s, host: uri.host, headers: headers, body: body }
      @responder.call(method, uri, headers, body)
    end
  end

  def seed_issuers
    CertificateIssuer.seed_defaults!
  end

  def issuer(code)
    CertificateIssuer.find_by_code(code) || (seed_issuers && CertificateIssuer.find_by_code(code))
  end

  def page(name)
    file_fixture("verification/#{name}.html").read
  end

  def response(body = "", status: 200, headers: { "content-type" => "text/html; charset=utf-8" })
    Verification::HttpClient::Response.new(status: status, headers: headers, body: body)
  end

  # Runs the block with every request answered by the block given here (or by replies, one per
  # request in order), and a fresh in-memory request count. Returns the FakeTransport.
  def with_fake_sites(*replies, responder: nil, cache: ActiveSupport::Cache::MemoryStore.new)
    queue = replies.dup
    transport = FakeTransport.new do |*args|
      reply = responder ? responder.call(*args) : queue.shift
      raise "unexpected request #{args[1]}" if reply.nil?

      reply.is_a?(Exception) ? raise(reply) : reply
    end
    Verification::HttpClient.with(transport: transport, cache: cache) { yield transport }
    transport
  end

  def with_auto_checks(enabled = true, &block)
    Verification::Config.with(auto_checks: enabled, &block)
  end

  def checker_for(klass, code: "212345678901", holder: "Juan Ortiz", completed_on: nil, expires_on: nil,
    verification_url: nil, barcodes: [])
    klass.new(code: code, verification_url: verification_url, holder_name: holder, completed_on: completed_on,
      expires_on: expires_on, barcodes: barcodes)
  end

  def qr(text, page: 1)
    { "page" => page, "text" => text }
  end
end
