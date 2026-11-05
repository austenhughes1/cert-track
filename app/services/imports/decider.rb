module Imports
  # Decides whether a matched import item can become a certificate without a person looking.
  #
  #   Imports::Decider.new(item).call     # => :accept or :review
  #   Imports::Decider.new(item).reasons  # => ["Auto-accept is turned off", ...] (empty for :accept)
  #
  # Auto-accept only when every rule holds: the type was matched by code, the person was
  # matched exactly (one active crew member), there is a completion date, there is an expiry
  # date or the type never expires, the model's confidence is at least
  # Imports::Config.auto_accept_confidence, the dates broke no rule (Imports::DateRules
  # problems are stored in item.error_message), its authenticity check didn't flag it
  # (Authenticity::FLAGGED_STATUSES, Phase 3b: a flag only for review, which would still count
  # once accepted, keeps it for a person too; so does a person's fake result that went back to
  # needs a check when its details changed) and isn't still waiting for the issuer's site
  # (issuer_check_pending: true, when Verification::CheckJob will ask it), and
  # Imports::Config.auto_accept_enabled? is on. The date rules are re-checked on the item's
  # proposed dates as a safety net.
  class Decider
    def initialize(item, today: Date.current, issuer_check_pending: false)
      @item = item
      @today = today
      @issuer_check_pending = issuer_check_pending
    end

    def call
      reasons.empty? ? :accept : :review
    end

    def reasons
      [
        ("Auto-accept is turned off" unless Imports::Config.auto_accept_enabled?),
        ("The certificate type was not matched by code" unless type_matched?),
        ("The crew member was not matched exactly" unless person_matched?),
        ("There is no completion date" if item.proposed_completed_on.blank?),
        ("There is no expiration date and the type expires" unless expiry_known?),
        ("The model's confidence is below #{Imports::Config.auto_accept_confidence}" unless confident?),
        ("The dates need checking" if date_problems?),
        ("The image is too small or blurry to read everything" if item.quality_flagged?),
        authenticity_reason,
        ("The issuer's site hasn't been asked yet" if @issuer_check_pending)
      ].compact
    end

    private
      attr_reader :item

      def type_matched?
        item.type_matched? && item.matched_certificate_type&.active?
      end

      def person_matched?
        item.person_matched? && item.matched_crew_member&.active?
      end

      def expiry_known?
        item.proposed_expires_on.present? || item.proposed_expiry_no_expiration? || (type_matched? && item.matched_certificate_type.never_expires?)
      end

      def confident?
        item.confidence.present? && item.confidence.to_f >= Imports::Config.auto_accept_confidence.to_f
      end

      # "Flagged for review: not found by issuer"; "Confirmed fake: ..." once a person recorded it;
      # and a person's fake result that a new reading turned back into needs a check (Imports::Reread).
      def authenticity_reason
        return "A person recorded it as fake before its details changed" if item.authenticity_method == Authenticity::DETAILS_CHANGED_METHOD
        return unless item.authenticity_flagged?

        "#{item.authenticity_confirmed_fake? ? "Confirmed fake" : "Flagged for review"}: #{item.authenticity_label.downcase_first}"
      end

      def date_problems?
        return true if item.error_message.present?

        completed_on = item.proposed_completed_on
        expires_on = item.proposed_expires_on
        (completed_on && completed_on > @today) || (completed_on && expires_on && expires_on < completed_on)
      end
  end
end
