module Verification
  module Checkers
    # National CPR Foundation's E-Verify (nationalcprfoundation.com/verify/): POSTs the
    # certificate ID the way its form does (certificate_code, an empty email, submit_user=Continue).
    #
    #   "No Results"             -> not_found
    #   a result with a name     -> verified, or mismatch when the name or a date shown differs
    #   anything else            -> unavailable
    class NationalCprFoundation < Base
      ENDPOINT = "https://nationalcprfoundation.com/verify/".freeze
      SITE = "National CPR Foundation".freeze
      NO_RESULTS = /\bno results?\b/i

      private
        def check
          doc = html(http.post(ENDPOINT, form: { "certificate_code" => code, "email" => "", "submit_user" => "Continue" }))
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
    end
  end
end
