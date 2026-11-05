module Imports
  # Decides an import item's image quality flags (ImageQualityFlags). All of it stays on the machine.
  #
  #   Imports::ImageQuality.unread_qr_pages(text, undecoded_pages: [ 2 ], decoded_pages: [ 1 ]) # => [ 2 ]
  #   Imports::ImageQuality.flags(item, certificate_data, dates)                                # => [ "qr_unreadable" ]
  module ImageQuality
    # The certificate's own words saying a code should be there (the Red Cross's "scan code or visit").
    QR_WORDS = /\b(?:scan\s+(?:to\s+verify|code|me|or\s+visit|this)|qr[\s-]?code)\b/i
    # Below this, the model itself says it isn't sure of what it read.
    CONFIDENCE_FLOOR = 0.6

    module_function

    # Pages with no decoded QR code where one was seen (Certificates::QrReader#undecoded_pages) or
    # where the text says there is one.
    def unread_qr_pages(text, undecoded_pages:, decoded_pages:)
      worded = Imports::TextExtractor.split_pages(text.to_s).select { |page| page.text.match?(QR_WORDS) }.map(&:number)
      ((Array(undecoded_pages) + worded).uniq - Array(decoded_pages)).sort
    end

    # certificate: the normalized model output for this item; dates: its Imports::DateRules result.
    def flags(item, certificate, dates)
      [ ("qr_unreadable" if item.unread_qr_pages.any?), ("hard_to_read" if scan?(item) && details_unread?(certificate, dates)) ].compact
    end

    def scan?(item)
      item.read_by_ocr || item.file.content_type.to_s.start_with?("image/")
    end

    def details_unread?(certificate, dates)
      certificate["holder_name"].blank? || certificate["certificate_name_as_printed"].blank? || dates.completed_on.nil? ||
        certificate["unreadable"].present? || certificate["confidence"].to_f < CONFIDENCE_FLOOR
    end
  end
end
