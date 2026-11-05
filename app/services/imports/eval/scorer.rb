module Imports
  module Eval
    # Compares one sample's extraction with its correct answer, field by field.
    #
    #   score = Imports::Eval::Scorer.new(expected: expected_json, actual: result.data).call
    #   score.fields["holder_name"]  # => [1, 1] (correct, total)
    #   score.missing                # => expected certificates the model did not return
    #   score.extra                  # => certificates the model returned that are not expected
    #
    # Each expected certificate is paired with the returned one that shares the most pages
    # (then the same holder, then the same type); an expected certificate with nothing left
    # to pair scores every field wrong. Fields:
    #   certificate_name_as_printed  the same words, whatever the case and punctuation, allowing a few
    #                          differences: it says what the certificate is, on the list or not
    #   certificate_type_code  exact code, case-insensitive. Only where the answer names a type: a
    #                          certificate needn't be on the list, so a blank answer isn't scored
    #   holder_name            equal after NameNormalizer ("ORTIZ, JUAN A." == "Juan Ortiz")
    #   completed_on, expires_on  the same YYYY-MM-DD, or both null
    #   certificate_number     letters and digits only, case-insensitive (informational)
    # Verification fields (Phase 3b), reported on their own and not part of the 90% bar. An
    # expected certificate without the key (an answer file written before Phase 3b) doesn't
    # score that field:
    #   certificate_issuer_code  exact code, case-insensitive
    #   verification_code        spaces and case ignored
    #   verification_url         scheme, "www.", host case, a trailing slash and query order ignored
    class Scorer
      SCORED_FIELDS = %w[certificate_name_as_printed certificate_type_code holder_name completed_on expires_on].freeze
      ANSWER_OPTIONAL_FIELDS = %w[certificate_name_as_printed certificate_type_code].freeze
      NAME_OVERLAP = 0.7 # the share of words two wordings of one printed name have in common
      INFO_FIELDS = %w[certificate_number].freeze
      VERIFICATION_FIELDS = %w[certificate_issuer_code verification_code verification_url].freeze
      FIELDS = (SCORED_FIELDS + INFO_FIELDS + VERIFICATION_FIELDS).freeze

      Score = Data.define(:fields, :expected_count, :matched, :missing, :extra, :pages, :mismatches) do
        def correct?(field)
          correct, total = fields.fetch(field)
          correct == total
        end
      end

      def initialize(expected:, actual:)
        @expected = certificates(expected)
        @actual = certificates(actual)
        @expected_pages = page_numbers(expected)
        @actual_pages = page_numbers(actual)
      end

      def call
        fields = FIELDS.index_with { [ 0, 0 ] }
        mismatches = []
        unpaired = @actual.dup
        missing = 0

        @expected.each do |want|
          got = best_match(want, unpaired)
          unpaired.delete(got) if got
          missing += 1 unless got
          FIELDS.each do |field|
            next unless self.class.scores?(want, field)

            same = got ? same?(field, want[field], got[field]) : false
            fields[field] = [ fields[field][0] + (same ? 1 : 0), fields[field][1] + 1 ]
            mismatches << { "field" => field, "expected" => want[field], "actual" => got&.dig(field) } unless same
          end
        end

        Score.new(fields: fields, expected_count: @expected.size, matched: @expected.size - missing, missing: missing,
          extra: unpaired.size, pages: [ (@expected_pages & @actual_pages).size, @expected_pages.size ], mismatches: mismatches)
      end

      # Whether an expected certificate is scored on field: always, except a verification field
      # its answer leaves out, and a name or type its answer leaves blank.
      def self.scores?(expected_certificate, field)
        return expected_certificate[field].present? if ANSWER_OPTIONAL_FIELDS.include?(field)

        VERIFICATION_FIELDS.exclude?(field) || expected_certificate.key?(field)
      end

      private
        def certificates(data)
          data = { "certificates" => data } if data.is_a?(Array)
          Array(data.is_a?(Hash) ? data["certificates"] : nil).select { |entry| entry.is_a?(Hash) }
        end

        def page_numbers(data)
          Array(data.is_a?(Hash) ? data["non_certificate_pages"] : nil).map(&:to_i).uniq
        end

        def best_match(want, candidates)
          candidates.max_by.with_index do |got, index|
            overlap = (Array(want["pages"]).map(&:to_i) & Array(got["pages"]).map(&:to_i)).size
            [ overlap, same?("holder_name", want["holder_name"], got["holder_name"]) ? 1 : 0,
              same?("certificate_type_code", want["certificate_type_code"], got["certificate_type_code"]) ? 1 : 0, -index ]
          end
        end

        def same?(field, want, got)
          return same_name?(want, got) if field == "certificate_name_as_printed"

          normalize(field, want) == normalize(field, got)
        end

        def same_name?(want, got)
          want, got = [ want, got ].map { |name| name.to_s.downcase.scan(/[a-z0-9]+/).to_set }
          return want == got if want.empty? || got.empty?

          (want & got).size.fdiv((want | got).size) >= NAME_OVERLAP
        end

        def normalize(field, value)
          text = value.to_s.strip
          return nil if text.empty?

          case field
          when "holder_name" then NameNormalizer.normalize(text).presence
          when "certificate_number" then text.upcase.gsub(/[^A-Z0-9]/, "").presence
          when "certificate_type_code", "certificate_issuer_code" then text.upcase
          when "verification_code" then text.gsub(/\s+/, "").upcase
          when "verification_url" then url(text)
          else text
          end
        end

        # "redcross.org/confirm?a=1&b=2" for "HTTPS://www.RedCross.org/confirm/?b=2&a=1".
        def url(text)
          text = text.gsub(/\s+/, "")
          uri = URI.parse(text.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? text : "https://#{text}")
          host = uri.host.to_s.downcase.delete_prefix("www.")
          port = ":#{uri.port}" if uri.port && uri.port != uri.default_port
          query = "?#{uri.query.split("&").sort.join("&")}" if uri.query.present?
          "#{host}#{port}#{uri.path.to_s.delete_suffix("/")}#{query}"
        rescue URI::InvalidURIError
          text.downcase
        end
    end
  end
end
