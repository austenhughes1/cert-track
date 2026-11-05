module Verification
  module Checkers
    # The OSHA Card Portal (oshacardportal.com), used by OTI Education Centers: GETs the page
    # the card's QR code opens, /portalapp/verify/<code>, which says VALID or NOT VALID.
    #
    #   NOT VALID                -> not_found
    #   VALID with a name        -> verified, or mismatch when the name or a date shown differs
    #   VALID without a name     -> needs_check (a forged card can reuse a real card's number)
    #   anything else            -> unavailable
    class OshaCardPortal < Base
      ENDPOINT = "https://www.oshacardportal.com/portalapp/verify/".freeze
      SITE = "OSHA Card Portal".freeze
      STATUS_TEXT = /\A(?:(?:this )?card(?: is)?:?\s*|status:?\s*)?(not valid|valid)[.!]?\z/i

      private
        def check
          doc = html(http.get("#{ENDPOINT}#{ERB::Util.url_encode(code)}"))
          status = card_status(doc)
          raise Unreadable, "#{SITE} showed a page CertTrack doesn't recognise." if status.nil?
          return not_found(issuer_status: status) if status == "NOT VALID"

          values = labeled_values(doc)
          found(name: shown_name(values), completed: first_value(values, COMPLETED_LABELS),
            expires: first_value(values, EXPIRES_LABELS), issuer_status: status)
        end

        # "VALID" or "NOT VALID" from an element that says only that (or "Status: VALID"), else nil.
        def card_status(doc)
          doc.css("h1, h2, h3, h4, h5, h6, p, div, span, strong, b, td, li, label").each do |node|
            next if node.element_children.any? { |child| child.text.squish.present? && child.name != "br" }

            match = text_of(node).match(STATUS_TEXT)
            return match[1].upcase if match
          end
          nil
        end
    end
  end
end
