module Imports
  # Turns an import item into a Certificate (the reviewer's Accept, or the pipeline's auto-accept).
  #
  #   certificate = Imports::Accept.new(item, user: Current.user, attributes: { completed_on: "2025-03-14" }).call
  #   Imports::Accept.new(item, user: nil, auto: true).call # pipeline, Imports::Decider said :accept
  #
  # attributes may override crew_member_id, certificate_type_id, completed_on, expires_on,
  # certificate_number, issued_by, notes, and (Phase 3b) certificate_issuer_id,
  # verification_code and verification_url; a key that is present but blank clears the value.
  # Without overrides the item's proposals are used (matched_crew_member and
  # matched_certificate_type hold the match or top suggestion, or a reviewer's pick saved with
  # "Save edits": person_match picked, type_match matched). The controller resolves the issuer
  # picker's "Other..." (CertificateIssuer.find_or_create_from_name!) before calling this.
  #
  # Issuer and verification (Phase 3b): the certificate gets the item's matched issuer (when a
  # person accepts, the match or top suggestion they were shown; when auto-accepting, only a
  # match), proposed_verification_code and proposed_verification_url, and its authenticity
  # check (authenticity_* columns: accepting a flagged item is a person's decision, and the
  # certificate stays flagged for review, counting by its dates; one a person recorded as not
  # found or not matching stays confirmed fake, so it counts as not valid and is left out of
  # packets, or is kept as history when a genuine certificate of its type is on file: see
  # Certificate). Unless the certificate's details differ from the ones that person checked on
  # the item (the review screen saves its edits before recording a result): a code typed over a
  # misread one, another issuer or link, or for a mismatch another person or card date. Then it
  # is needs_check again, saying what changed (Authenticity), and is checked again after the
  # accept commits. In a merge, the issuer is the first match among the items (else the first
  # suggestion), the code and link come together from the first item that has either (the back
  # of a card often carries the QR code), and the check is a person's confirmed fake if any, else
  # a flagged item's, else a person's result, else the most conclusive. When what the
  # certificate's check would compare isn't what that check compared (the reviewer changed the
  # issuer, code, link, person or a date of the card; a merge took them from another item; or a
  # person accepted a suggested issuer or person, which an item's check doesn't trust),
  # Verification::CheckJob checks the certificate again after the accept commits. So an issuer's
  # "Verified" for the printed name can't carry over to a certificate for someone else.
  #
  # Expiry: "No expiration" (the reviewer's tick, else the card said so) is kept whatever the type
  # says. A printed proposal, or one from a period printed on the card, keeps its source. A computed or missing one is left for the
  # Certificate model to derive from the final type and completion date (computed, or none
  # when the type never expires). A proposal a reviewer typed and saved ("Save edits",
  # source manual; older items saved it with no source) is manual. An overridden date is
  # printed when it equals a printed proposal, re-derived when it equals a computed one (so a
  # changed type or completion date is followed), blank means derive, and any other date is
  # manual. When the card's printed expiry could not be read (ImportItem#unreadable_expires_on,
  # on this item or a merged one), the expiry is never derived: unless the reviewer gives a
  # date (or the item's own printed one is kept), the accept is refused with
  # UNREADABLE_EXPIRY_MESSAGE, so a guessed date can't stand in for the one on the card.
  # Wording that says there is no expiry ("Never", "Does not expire") is not unreadable: the
  # normalizer treats it as not printed, so it is derived like any other.
  #
  # The certificate gets source import, import_item: item, the item's file (the same blob),
  # and verified_by/verified_at when a user accepts. Older certificates of the same type are
  # superseded by the model's rules. The item becomes accepted with certificate,
  # reviewed_by and reviewed_at, and lets go of its file: only its attachment goes, the blob
  # is the certificate's from then on. So deleting the certificate, or removing that file
  # from it, deletes the stored file too (Active Storage won't purge a blob still attached
  # anywhere), and import pages link to the certificate instead. Other items sharing the
  # blob (one photo holding several certificates) keep theirs until they are accepted
  # themselves; a rejected one keeps it for good.
  #
  # When the chosen person is the matcher's proposal (matched_crew_member with person_match
  # matched or suggested: an exact match, a suggestion that cleared the bar, or a member
  # created from this item) and the printed holder name is a new spelling for them, that
  # spelling is added to their name_aliases (CrewMember#add_alias!). A person picked by hand
  # learns nothing, since the AI may have misread the name: one chosen here, any other
  # listed candidate, or one saved with "Save edits" (person_match picked). Nor is a
  # spelling learned that is already an exact name of another member: that member's own
  # cards would stop matching exactly.
  #
  # All or nothing (a savepoint, so it nests in the pipeline's transaction). Raises
  # ActiveRecord::RecordInvalid with the certificate's errors (e.g. "Crew member must exist",
  # or the unreadable-expiry message on base), or NotReviewable (a RecordInvalid) when the
  # item was already accepted, rejected, is a duplicate, failed or is still processing.
  # Afterwards (unless auto, where the pipeline does it) each affected batch runs
  # check_completion!.
  class Accept
    # The item's status doesn't allow this review action. errors are on the item.
    class NotReviewable < ActiveRecord::RecordInvalid; end

    OVERRIDABLE_ATTRIBUTES = %i[crew_member_id certificate_type_id completed_on expires_on no_expiration certificate_number issued_by notes
      certificate_issuer_id verification_code verification_url].freeze
    # Least to most conclusive, for picking a merged certificate's authenticity check.
    AUTHENTICITY_RANK = %w[unchecked cannot_verify needs_check verified].freeze
    # %s is the text the AI read, e.g. "2027-06".
    UNREADABLE_EXPIRY_MESSAGE = %(The card's expiry ("%s") could not be read. Type the expiry date from the card.).freeze
    REVIEWABLE_STATUSES = %w[needs_review].freeze
    AUTO_ACCEPT_STATUSES = (ImportItem::PIPELINE_STATUSES + REVIEWABLE_STATUSES).freeze # the pipeline accepts mid-processing
    STATUS_MESSAGES = {
      "accepted" => "This item was already accepted.",
      "rejected" => "This item was already rejected.",
      "duplicate" => "This item is a duplicate of another file, so there is nothing to review.",
      "failed" => "This item failed to process, so there is nothing to review.",
      "pending" => "This item is still being processed.",
      "extracting" => "This item is still being processed.",
      "needs_review" => "This item is waiting for review."
    }.freeze

    class << self
      # Locks the item's row and checks its status as stored, without reloading the object
      # (files the pipeline attached in this transaction upload on commit; a reload would
      # drop them). Raises NotReviewable, with the reason on item.errors.
      def lock_for_review!(item, statuses: REVIEWABLE_STATUSES)
        status = item.persisted? ? ImportItem.where(id: item.id).lock.pick(:status) : nil
        return if statuses.include?(status)

        item.errors.add(:base, STATUS_MESSAGES.fetch(status, "This item no longer exists."))
        raise NotReviewable.new(item)
      end
    end

    # merged_items: further needs_review items whose files join the same certificate (Imports::Merge).
    def initialize(item, user:, attributes: {}, auto: false, merged_items: [])
      @item = item
      @user = user
      @attributes = attributes.to_h.with_indifferent_access.slice(*OVERRIDABLE_ATTRIBUTES)
      @auto = auto
      @merged_items = Array(merged_items).reject { |other| other.id == item.id }.uniq(&:id)
    end

    def call
      certificate = ImportItem.transaction(requires_new: true) do
        lock_items!
        certificate = build_certificate
        refuse_unread_expiry!(certificate)
        certificate.save!
        all_items.each { |accepted| finish(accepted, certificate) }
        certificate
      end

      Verification::CheckJob.perform_later(certificate) if recheck?(certificate)
      all_items.map(&:import_batch).uniq.each(&:check_completion!) unless @auto
      certificate
    end

    private
      attr_reader :item, :user

      def all_items
        [ item, *@merged_items ]
      end

      def lock_items!
        all_items.sort_by(&:id).each do |locked|
          statuses = @auto && locked.equal?(item) ? AUTO_ACCEPT_STATUSES : REVIEWABLE_STATUSES
          self.class.lock_for_review!(locked, statuses:)
        end
      end

      def build_certificate
        certificate = Certificate.new(
          crew_member: override(:crew_member_id) { |id| CrewMember.find_by(id: id) } || default(:crew_member_id, item.matched_crew_member),
          certificate_type: override(:certificate_type_id) { |id| CertificateType.find_by(id: id) } || default(:certificate_type_id, item.matched_certificate_type),
          completed_on: @attributes.key?(:completed_on) ? @attributes[:completed_on].presence : item.proposed_completed_on,
          certificate_number: @attributes.key?(:certificate_number) ? @attributes[:certificate_number] : item.proposed_certificate_number,
          issued_by: @attributes.key?(:issued_by) ? @attributes[:issued_by] : item.issuer_raw,
          notes: @attributes[:notes].presence,
          certificate_issuer: override(:certificate_issuer_id) { |id| CertificateIssuer.find_by(id: id) } ||
            default(:certificate_issuer_id, proposed_verification["certificate_issuer"]),
          verification_code: @attributes.key?(:verification_code) ? @attributes[:verification_code] : proposed_verification["verification_code"],
          verification_url: @attributes.key?(:verification_url) ? @attributes[:verification_url] : proposed_verification["verification_url"],
          source: :import, import_item_id: item.id, # by id: a refused certificate must not ride along on item.created_certificates
          verified_by: user, verified_at: (Time.current if user)
        )
        certificate.assign_attributes(authenticity_source.authenticity_attributes)
        certificate.quality_flags = all_items.flat_map(&:quality_flags).uniq
        assign_expiry(certificate)
        reset_stale_fake(certificate)
        blobs = all_items.filter_map { |accepted| accepted.file.blob if accepted.file.attached? }.uniq(&:id)
        certificate.files.attach(blobs) if blobs.any?
        certificate
      end

      # The record for an overridden id (nil when blank or unknown), or nil when not overridden.
      def override(key)
        return unless @attributes.key?(key)

        id = @attributes[key].presence
        id && yield(id)
      end

      def default(key, proposal)
        @attributes.key?(key) ? nil : proposal
      end

      # The issuer, code and link the items propose (see the class comment).
      def proposed_verification
        @proposed_verification ||= begin
          issuer = all_items.find(&:issuer_matched?)&.matched_certificate_issuer
          issuer ||= all_items.lazy.filter_map(&:matched_certificate_issuer).first unless @auto
          source = all_items.find { |accepted| accepted.proposed_verification_code.present? || accepted.proposed_verification_url.present? }
          { "certificate_issuer" => issuer, "verification_code" => source&.proposed_verification_code,
            "verification_url" => source&.proposed_verification_url }
        end
      end

      # A person's confirmed fake, else a flagged item's check (a merge never hides either), else a
      # person's result, else the most conclusive; ties go to item.
      def authenticity_source
        all_items.each_with_index.max_by do |accepted, index|
          by = if accepted.authenticity_confirmed_fake? then 3
          elsif accepted.authenticity_flagged? then 2
          elsif accepted.authenticity_set_by_person? then 1
          else 0
          end
          [ by, AUTHENTICITY_RANK.index(accepted.authenticity_status).to_i, -index ]
        end.first
      end

      # A person's not_found or mismatch on the item was about the details they checked (kept with
      # it, Authenticity). When the certificate's differ, it isn't confirmed fake (see the class comment).
      def reset_stale_fake(certificate)
        source = authenticity_source
        return unless source.authenticity_confirmed_fake?

        changed = source.authenticity_changed_since_check(source.authenticity_inputs(database: true), now: certificate.authenticity_inputs)
        certificate.assign_attributes(source.authenticity_reset_attributes(changed)) if changed.any?
      end

      # Whether what the certificate's check compares (Verification::Run: the issuer, code, link,
      # holder and the card's own dates) differs from what its copied check compared. An item's check
      # trusts the issuer only when issuer_match is matched, and holds the person to the member only
      # when matched or picked; a computed expiry is never compared. Never when auto-accepting (the
      # pipeline's own check covers the certificate, Imports::ProcessExtractionJob), nor over a
      # person's result, which Run leaves alone. Always when a person's fake result was reset.
      def recheck?(certificate)
        return false if @auto
        return true if certificate.authenticity_method == Authenticity::DETAILS_CHANGED_METHOD

        source = authenticity_source
        return false if source.authenticity_set_by_person?

        checked = [ (source.matched_certificate_issuer_id if source.issuer_matched?), source.proposed_verification_code,
          source.proposed_verification_url, (source.matched_crew_member_id if source.person_matched? || source.person_picked?),
          source.proposed_completed_on, (source.proposed_expires_on unless source.proposed_expiry_computed? || source.proposed_expiry_none? || source.proposed_expiry_printed_period?) ]
        now = [ certificate.certificate_issuer_id, certificate.verification_code, certificate.verification_url, certificate.crew_member_id,
          certificate.completed_on, (certificate.expires_on unless certificate.expiry_computed? || certificate.expiry_none? || certificate.expiry_printed_period?) ]
        now != checked
      end

      def assign_expiry(certificate)
        no_expiration = @attributes.key?(:no_expiration) ? ActiveModel::Type::Boolean.new.cast(@attributes[:no_expiration]) : item.proposed_expiry_no_expiration?
        return certificate.no_expiration = true if no_expiration

        proposed = item.proposed_expires_on
        date = @attributes.key?(:expires_on) ? ActiveModel::Type::Date.new.cast(@attributes[:expires_on].presence) : proposed
        overridden = @attributes.key?(:expires_on) && date != proposed

        if date.nil? || (!overridden && (item.proposed_expiry_computed? || item.proposed_expiry_none?))
          certificate.expires_on = nil # the model derives it: computed, or none
        else
          certificate.expires_on = date
          certificate.expires_on_source = !overridden && (item.proposed_expiry_printed? || item.proposed_expiry_printed_period?) ? item.proposed_expires_on_source : :manual
        end
      end

      # A card whose printed expiry the AI couldn't read gets no derived (computed or none)
      # expiry: the reviewer must type it. Raises RecordInvalid with the message on base,
      # alongside any other errors the certificate has.
      def refuse_unread_expiry!(certificate)
        return if certificate.expires_on.present? || certificate.expiry_no_expiration? # read, or the reviewer decided

        text = all_items.lazy.filter_map(&:unreadable_expires_on).first
        return unless text

        certificate.validate
        certificate.errors.add(:base, format(UNREADABLE_EXPIRY_MESSAGE, text))
        raise ActiveRecord::RecordInvalid, certificate
      end

      def finish(accepted, certificate)
        accepted.update!(status: :accepted, certificate:, reviewed_by: user, reviewed_at: Time.current)
        release_file(accepted)
        learn_alias(accepted, certificate.crew_member)
      end

      # The certificate holds the blob now; only the item's attachment row is deleted. A file
      # attached in this same transaction (Imports::Splitter's cut-out pages, in the pipeline)
      # uploads when it commits, and detach would cancel that upload: its row is deleted
      # without touching the pending upload, so this item object still shows it until reloaded.
      def release_file(accepted)
        return unless accepted.file.attached?

        if accepted.attachment_changes.key?("file")
          ActiveStorage::Attachment.where(id: accepted.file.attachment.id).delete_all
        else
          accepted.file.detach
        end
      end

      # Only from the matcher's own proposal (matched or suggested), never a hand pick.
      def learn_alias(accepted, crew_member)
        return if accepted.holder_name_raw.blank? || !(accepted.person_matched? || accepted.person_suggested?)
        return if accepted.matched_crew_member_id != crew_member.id || spelling_of_another_member?(accepted.holder_name_raw, crew_member)

        crew_member.add_alias!(accepted.holder_name_raw)
      end

      # The spelling is already an exact name or alias of another member (active or not), e.g.
      # one the reviewer turned down by creating a new member from this card. Learning it would
      # make that member's own name ambiguous, so their cards would stop matching exactly.
      def spelling_of_another_member?(spelling, crew_member)
        CrewMember.matching_normalized_name(spelling).any? { |member| member.id != crew_member.id }
      end
  end
end
