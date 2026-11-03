module Imports
  module Extraction
    # Turns whatever the model replied into the model output contract, so nothing downstream has
    # to trust it:
    #   - certificate_type_code kept only when it is an active master-list code (upcased), else null
    #   - pages: integers within the pages this call covered, sorted and unique; a certificate
    #     with none gets every page of the call
    #   - dates: valid ISO YYYY-MM-DD strings, else null. The dropped value is mentioned in
    #     notes and kept, capped, under "unreadable" ({ "expires_on" => "06/2027" }; the key
    #     is only there when a date was dropped), so the pipeline can tell "not printed" from
    #     "printed but unreadable" and never computes an expiry in place of a printed one
    #   - confidence: a number clamped to 0..1, rounded DOWN to 2 places (0.849 is 0.84, so it
    #     can't pass a 0.85 threshold); missing means 0
    #   - strings squished and capped in length; "null", "N/A", "unknown" and "" become null
    #   - entries with nothing in them are dropped (their pages count as non-certificate pages)
    #
    #   Imports::Extraction::Normalizer.new(pages: [1, 2], codes: %w[OSHA30 FLAGGER]).call(raw)
    #   # => { "certificates" => [...], "non_certificate_pages" => [2] }
    class Normalizer
      STRING_LIMITS = {
        "holder_name" => 120, "certificate_name_as_printed" => 200, "issuer" => 200,
        "certificate_number" => 80, "notes" => 500
      }.freeze
      DATE_FIELDS = %w[completed_on expires_on].freeze
      BLANK_VALUES = %w[null nil none n/a na unknown - ?].freeze
      ISO_DATE = /\A(\d{4})-(\d{2})-(\d{2})(?:[T ][\d:.]+Z?)?\z/
      UNREADABLE_LIMIT = 40
      CONTENT_FIELDS = %w[holder_name certificate_type_code certificate_name_as_printed certificate_number completed_on expires_on].freeze

      def initialize(pages:, codes:)
        @pages = Array(pages).map(&:to_i).sort
        @codes = codes.to_set { |code| code.to_s.upcase }
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
            "certificate_number" => string(entry["certificate_number"], "certificate_number"),
            "completed_on" => date(entry["completed_on"], "completed_on", notes, unreadable),
            "expires_on" => date(entry["expires_on"], "expires_on", notes, unreadable),
            "confidence" => confidence(entry["confidence"]),
            "notes" => nil
          }
          return if CONTENT_FIELDS.all? { |field| result[field].nil? }

          result["notes"] = [ string(entry["notes"], "notes"), *notes ].compact.join(" ").truncate(STRING_LIMITS["notes"]).presence
          result["unreadable"] = unreadable if unreadable.any?
          result
        end

        def page_list(value)
          Array(value).filter_map { |page| Integer(page.to_s, exception: false) }.select { |page| @pages.include?(page) }.uniq.sort
        end

        def string(value, field)
          return if value.nil? || value.is_a?(Hash) || value.is_a?(Array)

          text = value.to_s.squish
          return if text.empty? || BLANK_VALUES.include?(text.downcase)

          text.truncate(STRING_LIMITS.fetch(field, 200))
        end

        def code(value, notes)
          text = string(value, "certificate_number")&.upcase
          return if text.nil?
          return text if @codes.include?(text)

          notes << "Model suggested unknown type code #{text.truncate(20).inspect}."
          nil
        end

        def date(value, field, notes, unreadable)
          text = string(value, "notes")
          return if text.nil?

          match = ISO_DATE.match(text)
          return format("%04d-%02d-%02d", *match.captures.map(&:to_i)) if match && Date.valid_date?(*match.captures.map(&:to_i))

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
