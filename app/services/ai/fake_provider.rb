module Ai
  # A deterministic stand-in for the extraction model (AI_PROVIDER=fake): the default in tests,
  # and usable in development to demo imports without Cloudflare. No network, no randomness.
  #
  # It reads what a real model would see: the master list and issuer list from the system
  # prompt (<master_list> and <issuer_list> JSON lines) and the page texts from the prompt
  # ("=== page N ===" markers), and answers in the model output contract. A page is a
  # certificate when it has a line starting with CERTIFICATE (e.g. "CERTIFICATE OF
  # COMPLETION"); its fields come from the synthetic layout below, with labels matched case-
  # and whitespace-insensitively:
  #
  #   CERTIFICATE OF COMPLETION
  #   OSHA 30-Hour Construction Industry Outreach Training   <- certificate name as printed
  #   Awarded to: Juan A. Ortiz
  #   Certificate No: 30-1234567
  #   Completed: 2025-03-14
  #   Expires: 2028-03-14                                    <- optional
  #   Issued by: Example Safety Training LLC
  #   Verification code: RC-123456                           <- optional (Phase 3b)
  #   Verify at: redcross.org/confirm                        <- optional (Phase 3b)
  #
  # certificate_type_code is the master-list code whose name or alias appears in the name line
  # (longest match wins), else null; certificate_issuer_code is found the same way from the
  # issuer list and the "Issued by" line. Confidence is 0.95 when holder, name and completed
  # date are all present, else 0.6. Token usage is text length / 4, so Ai::Budget code runs
  # for real.
  #
  # Test hooks (reset with Ai::FakeProvider.reset!):
  #   Ai::FakeProvider.calls                         # => [Call(model:, system:, prompt:, images:)]
  #   Ai::FakeProvider.fail_next!(times: 2)          # next 2 calls raise Ai::QuotaExceeded
  #   Ai::FakeProvider.fail_next!(Ai::ProviderError.new("boom"))
  #   Ai::FakeProvider.with_quota_exceeded { ... }   # every call in the block raises
  #   Ai::FakeProvider.reply_next!({ "certificates" => [] }) # canned reply (Hash or String)
  class FakeProvider
    Call = Data.define(:model, :system, :prompt, :images)

    PAGE_MARKER = /^=== page (\d+) ===[ \t]*$/
    DOCUMENT_BLOCK = %r{<document>\n?(.*?)</document>}m
    MASTER_LIST_BLOCK = %r{<master_list>\n?(.*?)</master_list>}m
    ISSUER_LIST_BLOCK = %r{<issuer_list>\n?(.*?)</issuer_list>}m
    CERTIFICATE_LINE = /\Acertificate\b/i
    LABELS = {
      "holder_name" => /\Aawarded\s+to\s*:\s*(.*)\z/i,
      "certificate_number" => /\Acertificate\s+no\.?\s*:\s*(.*)\z/i,
      "completed_on" => /\Acompleted\s*:\s*(.*)\z/i,
      "expires_on" => /\Aexpires\s*:\s*(.*)\z/i,
      "validity_months" => /\Avalid\s+for\s+(\d+)\s+years?\z/i,
      "issuer" => /\Aissued\s+by\s*:\s*(.*)\z/i,
      "verification_code" => /\Averification\s+code\s*:\s*(.*)\z/i,
      "verification_url" => /\Averify\s+at\s*:\s*(.*)\z/i
    }.freeze
    ISO_DATE = /\b(\d{4}-\d{2}-\d{2})\b/
    QUOTA_MESSAGE = "4006: you have used up your daily free allocation of 10,000 neurons (fake)"

    @lock = Mutex.new
    @calls = []
    @failures = []
    @replies = []
    @quota_exceeded = false

    class << self
      def calls
        @lock.synchronize { @calls.dup }
      end

      def reset!
        @lock.synchronize do
          @calls = []
          @failures = []
          @replies = []
          @quota_exceeded = false
        end
      end

      def fail_next!(error = nil, times: 1)
        @lock.synchronize { times.times { @failures << (error || QuotaExceeded.new(QUOTA_MESSAGE)) } }
      end

      def reply_next!(reply, times: 1)
        content = reply.is_a?(String) ? reply : reply.to_json
        @lock.synchronize { times.times { @replies << content } }
      end

      def with_quota_exceeded
        @lock.synchronize { @quota_exceeded = true }
        yield
      ensure
        @lock.synchronize { @quota_exceeded = false }
      end

      # Records the call and returns [error_to_raise, canned_reply]; one of them, or neither.
      def take_hooks(call) # :nodoc:
        @lock.synchronize do
          @calls << call
          next [ QuotaExceeded.new(QUOTA_MESSAGE), nil ] if @quota_exceeded

          [ @failures.shift, @replies.shift ]
        end
      end
    end

    def initialize(model: Ai::Config::FAKE_MODEL)
      @model = model
    end

    # Returns an Ai::Client::Reply with the JSON reply text and token counts.
    def complete(system:, prompt:, images: [])
      error, canned = self.class.take_hooks(Call.new(model: @model, system: system, prompt: prompt, images: Array(images)))
      raise error if error

      content = canned || extract(system, prompt).to_json
      Client::Reply.new(content: content, input_tokens: tokens(system.to_s + prompt.to_s), output_tokens: tokens(content))
    end

    private
      def extract(system, prompt)
        master_list = parse_list(system, MASTER_LIST_BLOCK)
        issuer_list = parse_list(system, ISSUER_LIST_BLOCK)
        certificates = []
        non_certificate_pages = []

        parse_pages(prompt).each do |number, text|
          certificate = parse_certificate(text, master_list, issuer_list)
          if certificate
            certificates << certificate.merge("pages" => [ number ])
          else
            non_certificate_pages << number
          end
        end

        { "certificates" => certificates, "non_certificate_pages" => non_certificate_pages }
      end

      # { page number => text } from "=== page N ===" markers inside the <document> block.
      def parse_pages(prompt)
        document = prompt.to_s[DOCUMENT_BLOCK, 1] || prompt.to_s
        parts = document.split(PAGE_MARKER)
        preamble = parts.shift.to_s # text before the first marker
        return { 1 => preamble } if parts.empty?

        parts.each_slice(2).to_h { |number, text| [ number.to_i, text.to_s ] }
      end

      # The JSON-line entries of a <master_list> or <issuer_list> block that have a code.
      def parse_list(system, pattern)
        block = system.to_s[pattern, 1].to_s
        block.lines.filter_map do |line|
          entry = JSON.parse(line)
          entry if entry.is_a?(Hash) && entry["code"].present?
        rescue JSON::ParserError
          nil
        end
      end

      def parse_certificate(text, master_list, issuer_list)
        lines = text.lines.map(&:squish).compact_blank
        start = lines.index { |line| line.match?(CERTIFICATE_LINE) && !line.match?(LABELS["certificate_number"]) }
        return unless start

        fields = LABELS.keys.index_with(nil)
        lines.each do |line|
          LABELS.each { |field, pattern| fields[field] ||= line[pattern, 1].presence }
        end
        name = lines.drop(start + 1).find { |line| LABELS.values.none? { |pattern| line.match?(pattern) } }
        completed_on = date(fields["completed_on"])
        expires_on = date(fields["expires_on"])

        {
          "holder_name" => fields["holder_name"],
          "certificate_type_code" => list_code(name, master_list),
          "certificate_name_as_printed" => name,
          "issuer" => fields["issuer"],
          "certificate_issuer_code" => list_code(fields["issuer"], issuer_list, whole_words: true),
          "certificate_number" => fields["certificate_number"],
          "verification_code" => fields["verification_code"],
          "verification_url" => fields["verification_url"],
          "completed_on" => completed_on,
          "expires_on" => expires_on,
          "validity_months" => fields["validity_months"]&.to_i&.*(12),
          "no_expiration" => fields["expires_on"].to_s.match?(/\A(?:never|no expiration)/i),
          "confidence" => fields["holder_name"] && name && completed_on ? 0.95 : 0.6,
          "notes" => expires_on ? nil : "No expiration printed"
        }
      end

      # The code of the list entry whose name or alias appears in text (longest match wins), or nil.
      # whole_words: short issuer aliases ("AHA", "NSC") must not match inside other words.
      def list_code(text, list, whole_words: false)
        haystack = text.to_s.squish.downcase
        return if haystack.empty?

        best = list.filter_map do |entry|
          needles = [ entry["name"], *Array(entry["aliases"]) ].map { |value| value.to_s.squish.downcase }.compact_blank
          found = needles.select do |needle|
            whole_words ? haystack.match?(/(?<![a-z0-9])#{Regexp.escape(needle)}(?![a-z0-9])/) : haystack.include?(needle)
          end
          longest = found.max_by(&:length)
          [ entry["code"], longest.length ] if longest
        end.max_by(&:last)
        best&.first
      end

      def date(value)
        value.to_s[ISO_DATE, 1]
      end

      def tokens(text)
        (text.to_s.length / 4.0).ceil
      end
  end
end
