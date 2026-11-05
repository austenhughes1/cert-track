module Verification
  module Checkers
    # 360training's QR links (verify.360training.com/qrcode-certificate-validation?...) carry the
    # holder's name, course and issue date (Verification::QrLink#holder). This compares them with
    # the certificate locally; nothing is sent anywhere (the verification site disallows robots).
    #
    #   a different last name, or an issue date more than a day from completed_on -> mismatch
    #   matching details  -> needs_check: the QR code is not 360training's confirmation
    #   no such QR link   -> nil: there is nothing to compare, so Verification::Run's other rules
    #                        decide (a code or link for a person to use, or nothing to check with)
    #
    # The QR links come from the record's QR codes (barcodes) and its verification_url. A page or
    # photo with several people's cards carries several; the one whose details match the
    # certificate is compared, so a mismatch means none of them does.
    class QrDetails360training < Base
      SITE = "360training".freeze
      DOMAIN = "360training.com".freeze
      FIELD_WORDS = { "holder_last_name" => "last name", "completed_on" => "issue date" }.freeze

      def call
        comparisons = qr_holders.map do |holder|
          { "holder_last_name" => NameMatch.compare_last_name(holder_name, holder.last_name),
            "completed_on" => DateText.compare(completed_on, holder.issued_on) }.compact
        end
        return if comparisons.empty?

        # A QR code whose details match beats one with nothing to compare, which beats one that differs.
        compared = comparisons.max_by { |candidate| [ candidate.value?("differs") ? 0 : 1, candidate.value?("match") ? 1 : 0 ] }
        details = { "compared" => compared }

        if compared.value?("differs")
          fields = compared.select { |_, value| value == "differs" }.keys.map { |field| FIELD_WORDS.fetch(field) }
          result(:mismatch, "The 360training QR code's #{fields.to_sentence} #{fields.one? ? "doesn't" : "don't"} " \
            "match the certificate.", details)
        elsif compared.value?("match")
          result(:needs_check, "The QR code's details match the certificate; open the link to confirm with 360training.", details)
        else
          assisted("The 360training QR code carries the holder's details, but the certificate has none to compare.", details)
        end
      end

      def method_name
        "qr_details:#{self.class.key}"
      end

      private
        def qr_holders
          (qr_texts + [ @verification_url ]).filter_map { |text| QrLink.parse(text) }
            .select { |link| link.domain == DOMAIN && !link.hidden_host? }
            .filter_map(&:holder).uniq
        end

        def assisted(why, details = {})
          result(:needs_check, "#{why} Open the verification page to check it with 360training.", details)
        end
    end
  end
end
