module Verification
  module Checkers
    # National CPR Foundation's E-Verify (nationalcprfoundation.com/verify/): POSTs the
    # certificate ID the way its form does (certificate_code, an empty email, submit_user=Continue).
    #
    #   "No Results"             -> not_found
    #   a result with a name     -> verified, or mismatch when the name or a date shown differs
    #
    # A result is a table row whose cells are labelled (data-title: Name, Date, Course, Cert ID),
    # confirmed against the live site on real certificates (Nov 6, 2026). It shows the completion date
    # but no expiry. An older labelled layout is still read, in case the site changes back.
    #   anything else            -> unavailable
    class NationalCprFoundation < Base
      ENDPOINT = "https://nationalcprfoundation.com/verify/".freeze
      SITE = "National CPR Foundation".freeze
      NO_RESULTS = /\bno results?\b/i

      private
        def check
          doc = html(http.post(ENDPOINT, form: { "certificate_code" => code, "email" => "", "submit_user" => "Continue" }))
          row = result_row(doc)
          return found(name: cell(row, "Name"), completed: cell(row, "Date")) if row

          values = labeled_values(doc)
          name = shown_name(values)
          # A result wins over a "No Results" text elsewhere on the page (a hidden template).
          if name.present?
            return found(name: name, completed: first_value(values, COMPLETED_LABELS),
              expires: first_value(values, EXPIRES_LABELS), issuer_status: first_value(values, STATUS_LABELS))
          end
          return not_found if text_of(doc.at_css("body")).match?(NO_RESULTS)

          raise Unreadable, "#{SITE} showed a page CertTrack doesn't recognise."
        end

        # The result row for this code: a page can list several of a person's certificates.
        def result_row(doc)
          doc.css("tr").find { |row| cell(row, "Cert ID").to_s.casecmp?(code) && cell(row, "Name").present? }
        end

        def cell(row, title)
          text_of(row.at_css(%(td[data-title="#{title}"]))).presence
        end
    end
  end
end
