module Verification
  module Checkers
    # American Heart Association eCards (ecards.heart.org): POSTs the eCard code to the employer
    # lookup and reads table#tblECards (eCard Code, Student Name, eCard Status, Renewal Date).
    #
    #   status "Invalid"     -> not_found
    #   a row with a name    -> verified, or mismatch when the name or the renewal month differs
    #                           from the certificate's expiry month
    #   a row without a name -> needs_check (the student hasn't claimed the eCard yet)
    #   anything else        -> unavailable
    #
    # eCard codes are 12 digits; any other code is sent as it is.
    class AhaEcards < Base
      ENDPOINT = "https://ecards.heart.org/Student/MyeCards/VerifyECards".freeze
      SITE = "AHA eCards".freeze
      CODE_FORMAT = /\A\d{12}\z/ # a hint only

      private
        def check
          table = html(http.post(ENDPOINT, form: { "codes" => code })).at_css("table#tblECards")
          raise Unreadable, "#{SITE} showed a page CertTrack doesn't recognise." unless table

          row = ecard_row(table)
          raise Unreadable, "#{SITE} showed no row for this eCard." unless row

          status = row[:status]
          return not_found(issuer_status: status) if status.to_s.match?(/\binvalid\b/i)

          found(name: row[:name], expires: row[:renewal], issuer_status: status, expires_by_month: true)
        end

        # { code:, name:, status:, renewal: } for this code's row (or the only row), by header text.
        def ecard_row(table)
          headers = table.css("tr").first&.css("th, td").to_a.map { |cell| text_of(cell).downcase }
          columns = {
            code: headers.index { |header| header.include?("code") },
            name: headers.index { |header| header.include?("student") } ||
              headers.index { |header| header.include?("name") && !header.include?("course") },
            status: headers.index { |header| header.include?("status") },
            renewal: headers.index { |header| header.include?("renewal") || header.include?("expir") }
          }
          raise Unreadable, "#{SITE} showed a table CertTrack doesn't recognise." if columns[:code].nil? || columns[:status].nil?

          rows = table.css("tr").drop(1).map do |tr|
            cells = tr.css("td").map { |cell| text_of(cell) }
            columns.transform_values { |index| cells[index].presence if index }
          end.select { |row| row[:code] }
          rows.find { |row| same_code?(row[:code]) } || (rows.first if rows.one?)
        end

        def same_code?(shown)
          shown.delete("^A-Za-z0-9").casecmp?(code.delete("^A-Za-z0-9"))
        end
    end
  end
end
