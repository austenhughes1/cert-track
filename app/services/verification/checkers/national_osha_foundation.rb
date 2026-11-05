module Verification
  module Checkers
    # National OSHA Foundation's certificate verification (a 360training brand): GETs the page
    # its QR codes open, ?certificate_id=<code>, and reads table#elc_search-table (First Name,
    # Last Name, Course, Completion Date as yyyy-mm-dd).
    #
    #   a row                    -> verified, or mismatch when the name or the completion date
    #                               (within a day) differs
    #   a "no records" message   -> not_found
    #   HTTP 500, "critical error", anything else -> unavailable: the site has answered unknown IDs
    #                               with error pages, so an error is never taken as "not found"
    class NationalOshaFoundation < Base
      ENDPOINT = "https://www.nationaloshafoundation.com/certificate-verification/".freeze
      SITE = "National OSHA Foundation".freeze
      NO_RECORDS = /\bno (?:records?|results?|certificates?|matching certificates?)(?: (?:were|was))? found\b/i

      private
        def check
          doc = html(http.get("#{ENDPOINT}?#{URI.encode_www_form("certificate_id" => code)}"))
          page_text = text_of(doc.at_css("body"))
          raise Unreadable, "#{SITE} showed an error page." if page_text.match?(/critical error/i)

          row = certificate_row(doc.at_css("table#elc_search-table"))
          return found(name: row.values_at(:first, :last).compact.join(" "), completed: row[:completed]) if row
          return not_found if page_text.match?(NO_RECORDS)

          raise Unreadable, "#{SITE} showed a page CertTrack doesn't recognise."
        end

        # { first:, last:, completed: } from the table's first data row, or nil.
        def certificate_row(table)
          return if table.nil?

          headers = table.css("tr").first&.css("th, td").to_a.map { |cell| text_of(cell).downcase }
          columns = {
            first: headers.index { |header| header.include?("first") },
            last: headers.index { |header| header.include?("last") },
            completed: headers.index { |header| header.include?("completion") || header.include?("date") }
          }
          return if columns[:first].nil? || columns[:last].nil?

          table.css("tr").drop(1).each do |tr|
            cells = tr.css("td").map { |cell| text_of(cell) }
            row = columns.transform_values { |index| cells[index].presence if index }
            return row if row[:last]
          end
          nil
        end
    end
  end
end
