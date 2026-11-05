module Verification
  module Checkers
    # Shared by the checkers (see Verification::Checkers for the list).
    #
    #   checker = Checkers::OshaCardPortal.new(code: "ABC123", verification_url: nil, holder_name: "Juan Ortiz",
    #     completed_on: Date.new(2025, 3, 14), expires_on: nil, barcodes: [])
    #   checker.call # => a Verification::Result
    #
    # holder_name may be one name or several the holder goes by (Verification::NameMatch).
    # barcodes: [{ "page" => 1, "text" => "https://..." }], QR codes read from the certificate.
    # http: a Verification::HttpClient (tests pass one with a fake transport).
    #
    # A network checker defines ENDPOINT (where the code is sent; Verification::Run checks it is
    # on the issuer's own domains), SITE (the site's name in notes) and #check. A
    # HttpClient::Error, an HTTP error status or a page it can't read becomes an :unavailable result.
    class Base
      # The site answered, but not with a page the checker can read. reason: for the details.
      class Unreadable < StandardError
        attr_reader :reason

        def initialize(message, reason: "layout")
          super(message)
          @reason = reason
        end
      end

      NAME_LABELS = [ "student name", "customer name", "name", "full name", "holder", "card holder", "cardholder",
        "trainee", "trainee name", "participant", "participant name", "student" ].freeze
      FIRST_NAME_LABELS = [ "first name", "firstname", "given name" ].freeze
      LAST_NAME_LABELS = [ "last name", "lastname", "surname", "family name" ].freeze
      COMPLETED_LABELS = [ "issue date", "date issued", "issued", "issued on", "completion date", "date completed",
        "completed", "completed on", "date of completion", "training date", "course date" ].freeze
      EXPIRES_LABELS = [ "expiration date", "expiration", "expires", "expires on", "expiry date", "expiry",
        "valid until", "valid through", "renewal date", "recommended renewal date" ].freeze
      STATUS_LABELS = [ "status", "card status", "certificate status", "ecard status" ].freeze
      FIELD_WORDS = { "holder" => "name", "completed_on" => "completion date", "expires_on" => "expiry date" }.freeze

      def self.key
        CLASS_NAMES.key(name.demodulize)
      end

      def initialize(code:, verification_url:, holder_name:, completed_on:, expires_on:, barcodes:, http: nil)
        @code = code.to_s.squish.presence
        @verification_url = verification_url
        @holder_name = Array(holder_name).compact_blank
        @completed_on = completed_on
        @expires_on = expires_on
        @barcodes = Array(barcodes)
        @http = http
      end

      def call
        return unavailable("There's no verification code to send.", reason: "no_code") if @code.nil?

        check
      rescue HttpClient::Error => error
        unavailable(error.message, reason: error.reason)
      rescue Unreadable => error
        unavailable(error.message, reason: error.reason)
      end

      def method_name
        "automatic:#{self.class.key}"
      end

      private
        attr_reader :code, :holder_name, :completed_on, :expires_on

        def http
          @http ||= HttpClient.new
        end

        def site
          self.class::SITE
        end

        # The decoded texts of the QR codes ({ "page" =>, "text" => } entries, or bare strings).
        def qr_texts
          @barcodes.filter_map { |barcode| barcode.is_a?(Hash) ? (barcode["text"] || barcode[:text]) : barcode }.map(&:to_s)
        end

        # Parses a successful HTML response; an error status is :unavailable (Unreadable).
        def html(response)
          unless response.success?
            if [ 401, 403, 429 ].include?(response.status)
              raise Unreadable.new("#{site} refused it (HTTP #{response.status}).", reason: "blocked")
            end

            raise Unreadable.new("#{site} answered with an error (HTTP #{response.status}).", reason: "http_error")
          end
          Nokogiri::HTML5(response.body)
        end

        def text_of(node)
          node&.text.to_s.squish
        end

        # { "label" => "value" } from two-cell table rows, dt/dd pairs and "Label: value" elements
        # (labels downcased, without the colon). The first value of a label wins.
        def labeled_values(scope)
          values = {}
          scope.css("tr").each do |row|
            cells = row.css("th, td")
            add_label(values, text_of(cells[0]), text_of(cells[1])) if cells.size == 2
          end
          scope.css("dt").each { |term| add_label(values, text_of(term), text_of(term.at_xpath("following-sibling::dd[1]"))) }
          scope.css("p, li, div, span, label").each do |node|
            next if node.css("p, li, div, tr, table").any?

            label, value = text_of(node).split(/:\s*/, 2)
            add_label(values, label, value) if value && label.length <= 40
          end
          values
        end

        def add_label(values, label, value)
          label = label.to_s.delete_suffix(":").squish.downcase
          values[label] ||= value.to_s.squish if label.present? && value.present?
        end

        def first_value(values, labels)
          labels.lazy.filter_map { |label| values[label] }.first
        end

        # The name a labeled page shows: one name field, or first + last name fields.
        def shown_name(values)
          first_value(values, NAME_LABELS) ||
            [ first_value(values, FIRST_NAME_LABELS), first_value(values, LAST_NAME_LABELS) ].compact.join(" ").presence
        end

        # The result for a certificate the site found, from what the site shows: verified when the
        # name matches and every date shown matches, mismatch when any of them differs, needs_check
        # when there is no name to compare (the site shows none, or the certificate has none).
        # expires_by_month: compare the expiry by month only (a renewal month).
        def found(name:, completed: nil, expires: nil, issuer_status: nil, expires_by_month: false)
          compared = {
            "holder" => NameMatch.compare(holder_name, name),
            "completed_on" => DateText.compare(completed_on, completed),
            "expires_on" => DateText.compare(expires_on, expires, month_only: expires_by_month)
          }.compact
          issuer_status = issuer_status.to_s.squish.truncate(40).presence
          details = { "issuer_status" => issuer_status, "compared" => compared }.compact
          status_words = " (status: #{issuer_status})" if issuer_status

          if compared.value?("differs")
            fields = compared.select { |_, value| value == "differs" }.keys.map { |field| FIELD_WORDS.fetch(field) }
            result(:mismatch, "#{site} found this certificate#{status_words}, but its #{fields.to_sentence} " \
              "#{fields.one? ? "doesn't" : "don't"} match the certificate.", details)
          elsif compared["holder"] == "match"
            result(:verified, "#{site} found this certificate#{status_words}, and its details match.", details)
          else
            missing = name.blank? ? "but shows no name to compare" : "but the certificate has no holder name to compare"
            result(:needs_check, "#{site} found this certificate#{status_words} #{missing}; open the verification " \
              "page to check it by hand.", details)
          end
        end

        def not_found(issuer_status: nil)
          result(:not_found, "#{site} has no certificate with this code.", { "issuer_status" => issuer_status }.compact)
        end

        # why: a sentence saying what went wrong (it names the site or host, never the code).
        def unavailable(why, reason:)
          why = why.to_s.strip
          why += "." unless why.end_with?(".")
          result(:unavailable, "The automatic check with #{site} didn't work. #{why} Open the verification page " \
            "to check it by hand.", { "unavailable" => reason })
        end

        def result(status, note, details = {})
          Result.new(status: status, method: method_name, note: note, details: details)
        end
    end
  end
end
