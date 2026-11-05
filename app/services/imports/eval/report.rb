module Imports
  module Eval
    # The accuracy harness's printout: one line per sample, then per-field accuracy against the
    # 90% bar (PLAN.md, Phase 3), the verification fields on their own (Phase 3b: not part of
    # the bar), certificate counts, and the AI usage of the run.
    #
    #   report.field_accuracy                  # => { "holder_name" => [22, 24], ... }
    #   report.percent("holder_name")          # => 91.7
    #   report.meets_bar?                      # => true when name, type, holder and both dates are >= 90%
    #   puts report                            # the table
    class Report
      BAR = 90.0
      LABELS = {
        "certificate_name_as_printed" => "name", "certificate_type_code" => "type", "holder_name" => "holder", "completed_on" => "completed",
        "expires_on" => "expires", "certificate_number" => "number",
        "certificate_issuer_code" => "issuer", "verification_code" => "vcode", "verification_url" => "vlink"
      }.freeze
      NAME_WIDTH = 34

      attr_reader :rows, :skipped, :dir, :provider, :model, :vision_model, :vision_only, :stopped

      def initialize(rows:, skipped:, dir:, provider:, model:, vision_model:, vision_only: false, stopped: nil)
        @rows = rows
        @skipped = skipped
        @dir = dir
        @provider = provider
        @model = model
        @vision_model = vision_model
        @vision_only = vision_only
        @stopped = stopped
      end

      def scored_rows
        rows.select(&:score)
      end

      # { field => [correct, total] } over every sample, with failed samples' expected
      # certificates counted as wrong (an error is not a free pass).
      def field_accuracy
        @field_accuracy ||= Scorer::FIELDS.index_with do |field|
          rows.reduce([ 0, 0 ]) do |(correct, total), row|
            if row.score
              row_correct, row_total = row.score.fields.fetch(field)
              [ correct + row_correct, total + row_total ]
            else
              [ correct, total + expected_count(row, field) ]
            end
          end
        end
      end

      def percent(field)
        correct, total = field_accuracy.fetch(field)
        total.zero? ? 0.0 : (100.0 * correct / total).round(1)
      end

      def below_bar
        Scorer::SCORED_FIELDS.reject { |field| field_accuracy.fetch(field).last.zero? || percent(field) >= BAR }
      end

      def meets_bar?
        rows.any? && below_bar.empty?
      end

      def total(attribute)
        rows.sum { |row| row.public_send(attribute).to_i }
      end

      def to_s
        lines = []
        lines << "Extraction eval: provider=#{provider} model=#{model || "-"} vision=#{vision_model || "-"}" \
          "#{" (vision only: OCR text withheld, every page sent as an image)" if vision_only}"
        lines << "Samples: #{rows.size} scored from #{dir}#{" (#{skipped.size} skipped)" if skipped.any?}"
        lines << ""
        lines << table_header
        rows.each { |row| lines << table_row(row) }
        lines << ""
        lines << "Field accuracy (the bar is #{BAR.to_i}% on name, type, holder, completed and expires):"
        (Scorer::SCORED_FIELDS + Scorer::INFO_FIELDS).each { |field| lines << accuracy_line(field) }
        lines << "Verification fields (reported on their own, not part of the bar):"
        Scorer::VERIFICATION_FIELDS.each { |field| lines << accuracy_line(field) }
        lines << ""
        lines << certificate_line
        lines << "Usage: #{total(:requests)} requests, #{number(total(:input_tokens))} input tokens, " \
          "#{number(total(:output_tokens))} output tokens, #{number(total(:units))} #{unit_name}, #{rows.sum(&:seconds).round} s"
        lines << verdict
        lines << stopped if stopped
        skipped.each { |note| lines << "Skipped #{note}" }
        lines.join("\n")
      end

      private
        def table_header
          [ "sample".ljust(NAME_WIDTH), "certs".ljust(7), *LABELS.values.map { |label| label.ljust(9) }, unit_name.rjust(8), "  notes" ].join(" ")
        end

        def table_row(row)
          name = row.sample.name.truncate(NAME_WIDTH).ljust(NAME_WIDTH)
          return [ name, "error".ljust(7), "  #{row.error.to_s.squish.truncate(160)}" ].join(" ") unless row.score

          score = row.score
          certs = "#{score.matched}/#{score.expected_count}#{"+#{score.extra}" if score.extra.positive?}"
          cells = LABELS.keys.map do |field|
            correct, field_total = score.fields.fetch(field)
            (field_total.zero? ? "-" : "#{correct}/#{field_total}").ljust(9)
          end
          [ name, certs.ljust(7), *cells, number(row.units).rjust(8), "  #{notes(score)}" ].join(" ").rstrip
        end

        # The first wrong fields, the bar's before the verification fields.
        def notes(score)
          wrong = score.mismatches.reject { |mismatch| Scorer::INFO_FIELDS.include?(mismatch["field"]) }
          wrong = wrong.sort_by.with_index { |mismatch, index| [ Scorer::VERIFICATION_FIELDS.include?(mismatch["field"]) ? 1 : 0, index ] }
          wrong.first(3).map do |mismatch|
            "#{LABELS.fetch(mismatch["field"])}: want #{mismatch["expected"].inspect}, got #{mismatch["actual"].inspect}"
          end.join("; ").truncate(160)
        end

        def accuracy_line(field)
          correct, field_total = field_accuracy.fetch(field)
          if Scorer::VERIFICATION_FIELDS.include?(field) && field_total.zero?
            return "  #{LABELS.fetch(field).ljust(10)} #{"-".rjust(7)}  #{"-".rjust(6)}  (no answer file has #{field} yet)"
          end

          status = if Scorer::INFO_FIELDS.include?(field) then "(informational)"
          elsif Scorer::VERIFICATION_FIELDS.include?(field) then "(reported, not part of the bar)"
          elsif percent(field) >= BAR then "meets the bar"
          else "below the bar"
          end
          "  #{LABELS.fetch(field).ljust(10)} #{"#{correct}/#{field_total}".rjust(7)}  #{format("%5.1f%%", percent(field))}  #{status}"
        end

        def certificate_line
          expected = rows.sum { |row| expected_count(row) }
          found = scored_rows.sum { |row| row.score.matched }
          extra = scored_rows.sum { |row| row.score.extra }
          pages_found = scored_rows.sum { |row| row.score.pages.first }
          pages_expected = scored_rows.sum { |row| row.score.pages.last }
          errors = rows.count(&:error)
          "Certificates: #{expected} expected, #{found} found, #{extra} extra. Non-certificate pages: " \
            "#{pages_found}/#{pages_expected} identified. Errors: #{errors}."
        end

        def verdict
          return "Verdict: nothing was scored." if rows.empty?
          return "Verdict: meets the #{BAR.to_i}% bar on every scored field." if meets_bar?

          "Verdict: below the #{BAR.to_i}% bar on #{below_bar.map { |field| LABELS.fetch(field) }.to_sentence}."
        end

        # The expected certificates of a row (scored on field, when given).
        def expected_count(row, field = nil)
          return row.score.expected_count if row.score && field.nil?

          expected = Array(row.sample.expected["certificates"]).select { |certificate| certificate.is_a?(Hash) }
          field ? expected.count { |certificate| Scorer.scores?(certificate, field) } : expected.size
        rescue JSON::ParserError
          0
        end

        def unit_name
          Ai::Config.daily_allocation?(provider) ? "neurons" : "tokens"
        end

        def number(value)
          ActiveSupport::NumberHelper.number_to_delimited(value.to_i)
        end
    end
  end
end
