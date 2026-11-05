module Ask
  # Shared phrasing for answers. Dates read "Mar 14, 2025", as ComplianceHelper#format_date.
  module Wording
    INLINE_LIMIT = 10 # names listed in an answer before "and N more"

    module_function

    def date(value)
      value.to_date.strftime("%b %-d, %Y")
    end

    def quote(text)
      "“#{text}”"
    end

    # "today", "tomorrow", "in 12 days", "3 days ago".
    def in_days(days)
      case days
      when 0 then "today"
      when 1 then "tomorrow"
      when 2.. then "in #{days} days"
      else "#{-days} #{"day".pluralize(-days)} ago"
      end
    end

    # "1 person", "3 people", "2 certificates".
    def count(number, singular, plural = singular.pluralize)
      "#{number} #{number == 1 ? singular : plural}"
    end

    # "a, b and c", or "a, b ... and 4 more" past INLINE_LIMIT.
    def sentence(items, limit: INLINE_LIMIT)
      return items.to_sentence if items.size <= limit

      [ *items.first(limit), "#{items.size - limit} more" ].to_sentence
    end

    # "a or b", "a, b or c".
    def either(items)
      items.to_sentence(two_words_connector: " or ", last_word_connector: " or ")
    end

    def possessive(name)
      "#{name}'s"
    end

    # "confirmed fake: not found by issuer", for a certificate a person checked with its issuer and
    # recorded as not found or not matching (Authenticity#authenticity_confirmed_fake?): it counts
    # as not valid.
    def confirmed_fake(certificate)
      "confirmed fake: #{certificate.authenticity_label.downcase}"
    end

    # "flagged for review: suspicious link", for a certificate an automatic check, a QR code's
    # details or a lookalike link flagged (Authenticity#authenticity_flagged_for_review?): it still
    # counts by its dates until someone checks it with the issuer.
    def flagged_for_review(certificate)
      "flagged for review: #{certificate.authenticity_label.downcase}"
    end

    # "no expiration", "expired Oct 29, 2026", "expires in 10 days, Nov 13, 2026" (within
    # the 30-day expiring window) or "expires Dec 7, 2027".
    def expiry(expires_on, today:)
      return "no expiration" if expires_on.nil?

      days = (expires_on - today).to_i
      if days.negative? then "expired #{date(expires_on)}"
      elsif days <= Compliance::EXPIRING_WINDOW then "expires #{in_days(days)}, #{date(expires_on)}"
      else "expires #{date(expires_on)}"
      end
    end
  end
end
