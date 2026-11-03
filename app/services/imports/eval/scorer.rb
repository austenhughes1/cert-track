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
    #   certificate_type_code  exact code, case-insensitive (null must be null)
    #   holder_name            equal after NameNormalizer ("ORTIZ, JUAN A." == "Juan Ortiz")
    #   completed_on, expires_on  the same YYYY-MM-DD, or both null
    #   certificate_number     letters and digits only, case-insensitive (informational)
    class Scorer
      SCORED_FIELDS = %w[certificate_type_code holder_name completed_on expires_on].freeze
      INFO_FIELDS = %w[certificate_number].freeze
      FIELDS = (SCORED_FIELDS + INFO_FIELDS).freeze

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
            same = got ? same?(field, want[field], got[field]) : false
            fields[field] = [ fields[field][0] + (same ? 1 : 0), fields[field][1] + 1 ]
            mismatches << { "field" => field, "expected" => want[field], "actual" => got&.dig(field) } unless same
          end
        end

        Score.new(fields: fields, expected_count: @expected.size, matched: @expected.size - missing, missing: missing,
          extra: unpaired.size, pages: [ (@expected_pages & @actual_pages).size, @expected_pages.size ], mismatches: mismatches)
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
          normalize(field, want) == normalize(field, got)
        end

        def normalize(field, value)
          text = value.to_s.strip
          return nil if text.empty?

          case field
          when "holder_name" then NameNormalizer.normalize(text).presence
          when "certificate_number" then text.upcase.gsub(/[^A-Z0-9]/, "").presence
          when "certificate_type_code" then text.upcase
          else text
          end
        end
    end
  end
end
