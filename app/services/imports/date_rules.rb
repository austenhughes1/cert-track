module Imports
  # Turns the dates the model read off a card into the proposed dates for an import item.
  #
  #   result = Imports::DateRules.new(completed_on: "2025-03-14", expires_on: nil, certificate_type: flagger).call
  #   result.completed_on      # => Fri, 14 Mar 2025
  #   result.expires_on        # => Sun, 14 Mar 2028 (completed + 36 months)
  #   result.expires_on_source # => :computed
  #   result.errors            # => []
  #
  # Dates are ISO YYYY-MM-DD strings (or Date objects). In order (owner's rule, Nov 5, 2026):
  # a printed expiry wins (:printed); a certificate that explicitly says it has no expiration
  # (no_expiration:) gives :no_expiration; a type that never expires gives :none (OSHA 10 and 30,
  # even if the model reports a validity period); a validity period printed on the card
  # (validity_months:) gives :printed_period; then the type's validity gives :computed; with no
  # type yet, CertificateType::DEFAULT_VALIDITY_MONTHS does (:computed, so the review form works
  # it out again from the type the reviewer picks). With no completion date to count from, nil.
  # Problems never raise: they are listed in errors (plain sentences for the review screen)
  # so the item goes to review. A completion date in the future, or an expiry before the
  # completion date, is kept so the reviewer can see and fix it. A date that can't be read
  # becomes nil, and an unreadable printed expiry is not replaced by a computed one.
  class DateRules
    Result = Data.define(:completed_on, :expires_on, :expires_on_source, :errors) do
      def errors?
        errors.any?
      end
    end

    ISO_DATE = /\A(\d{4})-(\d{1,2})-(\d{1,2})\z/

    def initialize(completed_on:, expires_on:, certificate_type:, validity_months: nil, no_expiration: false, today: Date.current)
      @raw_completed_on = completed_on
      @raw_expires_on = expires_on
      @certificate_type = certificate_type
      @validity_months = validity_months
      @no_expiration = no_expiration
      @today = today
    end

    def call
      errors = []
      completed_on = parse(@raw_completed_on, "completion", errors)
      printed_expiry = parse(@raw_expires_on, "expiration", errors)
      expiry_unreadable = printed_expiry.nil? && present?(@raw_expires_on)

      if completed_on && completed_on > @today
        errors << "The completion date #{completed_on.iso8601} is in the future."
      end

      expires_on, source = expiry(completed_on, printed_expiry, expiry_unreadable)

      if completed_on && expires_on && expires_on < completed_on
        errors << "The expiration date #{expires_on.iso8601} is before the completion date #{completed_on.iso8601}."
      end

      Result.new(completed_on:, expires_on:, expires_on_source: source, errors:)
    end

    private
      def expiry(completed_on, printed_expiry, expiry_unreadable)
        return [ printed_expiry, :printed ] if printed_expiry
        return [ nil, nil ] if expiry_unreadable
        return [ nil, :no_expiration ] if @no_expiration
        return [ nil, :none ] if @certificate_type&.never_expires?
        return [ nil, nil ] if completed_on.nil?
        return [ completed_on.advance(months: @validity_months), :printed_period ] if @validity_months

        months = @certificate_type&.validity_months || CertificateType::DEFAULT_VALIDITY_MONTHS
        [ completed_on.advance(months: months), :computed ]
      end

      def parse(value, label, errors)
        return value.to_date if value.is_a?(Date) || value.is_a?(Time)
        return unless present?(value)

        text = value.to_s.strip
        match = ISO_DATE.match(text)
        year, month, day = match&.captures&.map(&:to_i)
        return Date.new(year, month, day) if match && Date.valid_date?(year, month, day)

        errors << "The #{label} date \"#{text.truncate(40)}\" is not a valid YYYY-MM-DD date."
        nil
      end

      def present?(value)
        value.to_s.strip.present?
      end
  end
end
