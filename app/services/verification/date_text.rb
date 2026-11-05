module Verification
  # Dates as issuers' pages and QR links print them, and how they compare with a certificate's.
  #
  #   Verification::DateText.parse("03/14/2025")   # => #<IssuerDate 2025-03-14, month_only: false>
  #   Verification::DateText.parse("2025-03-14")   # => same
  #   Verification::DateText.parse("03/2027")      # => #<IssuerDate 2027-03-01, month_only: true>
  #   Verification::DateText.parse("March 2027")   # => same
  #   Verification::DateText.compare(Date.new(2025, 3, 15), "03/14/2025") # => "match" (within a day)
  #
  # US order (month first) for slashed dates, as the issuers in config/certificate_issuers.yml use.
  module DateText
    IssuerDate = Data.define(:date, :month_only)

    DAY_FORMATS = [ "%Y-%m-%d", "%m/%d/%Y", "%m-%d-%Y", "%B %d, %Y", "%b %d, %Y", "%B %d %Y", "%b %d %Y", "%d %B %Y", "%d %b %Y" ].freeze
    MONTH_FORMATS = [ "%m/%Y", "%m-%Y", "%Y-%m", "%B %Y", "%b %Y" ].freeze
    TOLERANCE = 1 # days

    module_function

    # An IssuerDate, or nil when the text isn't a date in one of the formats above.
    def parse(text)
      text = text.to_s.squish.delete_suffix(".")
      return if text.blank?

      DAY_FORMATS.each do |format|
        date = strict_parse(text, format)
        return IssuerDate.new(date: date, month_only: false) if date
      end
      MONTH_FORMATS.each do |format|
        date = strict_parse(text, format)
        return IssuerDate.new(date: date, month_only: true) if date
      end
      nil
    end

    # "match" / "differs" for a certificate's date and the issuer's, or nil when either is missing
    # or unreadable. A full date matches within TOLERANCE days; a month-only date (an AHA renewal
    # month), or any date with month_only: true, matches the same month.
    def compare(expected, shown, month_only: false)
      shown = parse(shown) unless shown.is_a?(IssuerDate)
      return if expected.nil? || shown.nil?

      same = if shown.month_only || month_only
        expected.year == shown.date.year && expected.month == shown.date.month
      else
        (expected - shown.date).abs <= TOLERANCE
      end
      same ? "match" : "differs"
    end

    # strptime ignores trailing text and reads "25" as the year 25, so the date must print back as
    # the text (with or without zero padding: "3/4/2025").
    def strict_parse(text, format)
      date = Date.strptime(text, format)
      unpadded = format.gsub("%m", "%-m").gsub("%d", "%-d")
      date if date.year >= 1900 && [ format, unpadded ].any? { |candidate| date.strftime(candidate).casecmp?(text) }
    rescue Date::Error
      nil
    end
    private_class_method :strict_parse
  end
end
