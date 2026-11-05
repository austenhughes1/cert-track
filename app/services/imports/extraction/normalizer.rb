module Imports
  module Extraction
    # Turns whatever the model replied into the model output contract, so nothing downstream has
    # to trust it:
    #   - certificate_type_code kept only when it is an active certificate type code (upcased), else null
    #   - pages: integers within the pages this call covered, sorted and unique; a certificate
    #     with none gets every page of the call
    #   - dates: valid ISO YYYY-MM-DD strings, else null. The dropped value is mentioned in
    #     notes and kept, capped, under "unreadable" ({ "expires_on" => "06/2027" }; the key
    #     is only there when a date was dropped), so the pipeline can tell "not printed" from
    #     "printed but unreadable" and never computes an expiry in place of a printed one. An
    #     expiry that says there is none ("Never", "Does not expire", "Lifetime": NO_EXPIRY) is
    #     not printed: null with a note, not unreadable. It sets no_expiration, as does the model's
    #     own no_expiration: true, unless it only says "N/A" (the type's rule then gives the
    #     expiry) or a date was read. Only an explicit statement counts (owner's rule, Nov 5, 2026)
    #   - confidence: a number clamped to 0..1, rounded DOWN to 2 places (0.849 is 0.84, so it
    #     can't pass a 0.85 threshold); missing means 0
    #   - strings squished and capped in length; "null", "N/A", "unknown" and "" become null
    #   - certificate_issuer_code (Phase 3b) kept only when it is an active issuer's code
    #     (upcased), else null with a note, like the type code
    #   - verification_code: squished; null when longer than its limit (cut short, it would check
    #     the wrong certificate). verification_url: spaces removed (OCR splits addresses), and null
    #     unless it looks like a web address (a dotted host ending in letters, no e-mail address)
    #   - entries with nothing in them are dropped (their pages count as non-certificate pages)
    #
    #   Imports::Extraction::Normalizer.new(pages: [1, 2], codes: %w[OSHA30 FLAGGER]).call(raw)
    #   # => { "certificates" => [...], "non_certificate_pages" => [2] }
    #
    # issuer_codes: the active issuer codes; left out, they are looked up when a reply names one.
    class Normalizer
      STRING_LIMITS = {
        "holder_name" => 120, "certificate_name_as_printed" => 200, "issuer" => 200,
        "certificate_number" => 80, "notes" => 500
      }.freeze
      VERIFICATION_CODE_LIMIT = 80
      VERIFICATION_URL_LIMIT = 500
      WEB_HOST = /\.[a-z]{2,}\z/ # ends in a top-level domain: not "30.5"
      DATE_FIELDS = %w[completed_on expires_on].freeze
      MAX_VALIDITY_MONTHS = 240
      BLANK_VALUES = %w[null nil none n/a na unknown - ?].freeze
      ISO_DATE = /\A(\d{4})-(\d{2})-(\d{2})(?:[T ][\d:.]+Z?)?\z/
      # An expiry that says there is none, the whole text, perhaps after a label: "Never",
      # "Expiration date: never", "Does not expire", "No expiration date", "Non-expiring",
      # "Lifetime", "Valid indefinitely", "Expires: N/A". Anything with a date in it is not.
      NO_EXPIRY = /\A(?:(?:expires|expiration|expiry|exp|valid)(?:\s(?:date|on|until|thru|through))?\W+)?
        (?:never(?:\sexpires?)?|does\s?n[o'’]?t\sexpire|no\s(?:expiration|expiry)(?:\sdate)?|non[-\s]?expiring|
          lifetime|for\slife|permanent|indefinite(?:ly)?|not\sapplicable|none|n\/?a)\W*\z/ix
      UNREADABLE_LIMIT = 40
      CONTENT_FIELDS = %w[holder_name certificate_type_code certificate_name_as_printed certificate_number completed_on expires_on].freeze

      def initialize(pages:, codes:, issuer_codes: nil)
        @pages = Array(pages).map(&:to_i).sort
        @codes = codes.to_set { |code| code.to_s.upcase }
        @issuer_codes = issuer_codes&.to_set { |code| code.to_s.upcase }
      end

      def call(raw)
        raw = { "certificates" => raw } if raw.is_a?(Array)
        raw = {} unless raw.is_a?(Hash)

        certificates = Array(raw["certificates"]).filter_map { |entry| certificate(entry) if entry.is_a?(Hash) }
        claimed = certificates.flat_map { |entry| entry["pages"] }.to_set
        non_certificate_pages = (page_list(raw["non_certificate_pages"]) + (@pages - claimed.to_a)).uniq.sort - claimed.to_a

        { "certificates" => certificates, "non_certificate_pages" => non_certificate_pages }
      end

      private
        def certificate(entry)
          notes = []
          unreadable = {}
          result = {
            "pages" => page_list(entry["pages"]).presence || @pages,
            "holder_name" => string(entry["holder_name"], "holder_name"),
            "certificate_type_code" => code(entry["certificate_type_code"], notes),
            "certificate_name_as_printed" => string(entry["certificate_name_as_printed"], "certificate_name_as_printed"),
            "issuer" => string(entry["issuer"], "issuer"),
            "certificate_issuer_code" => issuer_code(entry["certificate_issuer_code"], notes),
            "certificate_number" => string(entry["certificate_number"], "certificate_number"),
            "verification_code" => verification_code(entry["verification_code"]),
            "verification_url" => verification_url(entry["verification_url"]),
            "completed_on" => date(entry["completed_on"], "completed_on", notes, unreadable),
            "expires_on" => date(entry["expires_on"], "expires_on", notes, unreadable),
            "validity_months" => validity_months(entry["validity_months"]),
            "no_expiration" => no_expiration?(entry),
            "confidence" => confidence(entry["confidence"]),
            "notes" => nil
          }
          return if CONTENT_FIELDS.all? { |field| result[field].nil? }

          result["notes"] = [ string(entry["notes"], "notes"), *notes ].compact.join(" ").truncate(STRING_LIMITS["notes"]).presence
          result["unreadable"] = unreadable if unreadable.any?
          result
        end

        # A whole number of months, also from "24", "24 months" or "2 years"; else nil.
        def validity_months(value)
          months = case value
          when Numeric then value.to_i if value == value.to_i
          when String
            number, unit = value.squish.downcase.match(/\A(\d{1,3})(?:\s*(months?|mos?|years?|yrs?))?\z/)&.captures
            number && (unit&.start_with?("y") ? number.to_i * 12 : number.to_i)
          end
          months if months&.between?(1, MAX_VALIDITY_MONTHS)
        end

        # A read date beats it, and "N/A" isn't saying the certificate has no expiration.
        def no_expiration?(entry)
          text = squished(entry["expires_on"])
          return false if text&.match?(ISO_DATE)

          [ true, "true" ].include?(entry["no_expiration"]) ||
            (text.present? && NO_EXPIRY.match?(text) && !text.match?(%r{\b(?:n/?a|not applicable)\b}i))
        end

        def page_list(value)
          Array(value).filter_map { |page| Integer(page.to_s, exception: false) }.select { |page| @pages.include?(page) }.uniq.sort
        end

        def string(value, field)
          squished(value)&.truncate(STRING_LIMITS.fetch(field, 200))
        end

        # The squished text, or nil for a blank, a placeholder ("N/A") or a non-string.
        def squished(value)
          return if value.nil? || value.is_a?(Hash) || value.is_a?(Array)

          text = value.to_s.squish
          text unless text.empty? || BLANK_VALUES.include?(text.downcase)
        end

        def code(value, notes)
          text = string(value, "certificate_number")&.upcase
          return if text.nil?
          return text if @codes.include?(text)

          notes << "Model suggested unknown type code #{text.truncate(20).inspect}."
          nil
        end

        def issuer_code(value, notes)
          text = string(value, "certificate_number")&.upcase
          return if text.nil?
          return text if issuer_codes.include?(text)

          notes << "Model suggested unknown issuer code #{text.truncate(20).inspect}."
          nil
        end

        def issuer_codes
          @issuer_codes ||= CertificateIssuer.active.pluck(:code).to_set
        end

        def verification_code(value)
          text = squished(value)
          text if text && text.length <= VERIFICATION_CODE_LIMIT
        end

        def verification_url(value)
          text = squished(value)&.gsub(/\s+/, "")
          return if text.nil? || text.length > VERIFICATION_URL_LIMIT || text.include?("@")

          text if CertificateIssuer.host_of(Certificate.normalize_verification_url(text))&.match?(WEB_HOST)
        end

        def date(value, field, notes, unreadable)
          text = string(value, "notes")
          return if text.nil?

          match = ISO_DATE.match(text)
          return format("%04d-%02d-%02d", *match.captures.map(&:to_i)) if match && Date.valid_date?(*match.captures.map(&:to_i))

          if field == "expires_on" && NO_EXPIRY.match?(text) # no date printed; no_expiration? decides what that means
            notes << "No expiry date printed (the card says #{text.truncate(30).inspect})."
            return
          end

          notes << "Unreadable #{field} #{text.truncate(30).inspect} dropped."
          unreadable[field] = text.truncate(UNREADABLE_LIMIT)
          nil
        end

        def confidence(value)
          number = Float(value.to_s.delete("%").strip, exception: false)
          return 0.0 if number.nil? || number.nan?

          number /= 100 if number > 1 && number <= 100 # "92" or "92%" meant a percentage
          BigDecimal(number.clamp(0.0, 1.0).to_s).floor(2).to_f # in decimal: (0.29 * 100).floor would give 28
        end
    end
  end
end
