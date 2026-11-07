# The import review queue (docs/PLAN.md, "Bulk import pipeline", step 10): one screen per
# item, the file on the left and the AI's proposal on the right, editable. Accept, reject,
# skip, "create crew member from this" and front/back merge go through the Imports::* review
# services (which also run the batch's check_completion!); after each the reviewer moves on
# to the next item. "Read again" (Imports::Reread) also takes rejected and failed items, from
# the batch page. Editors only: the queue shows personal data from the cards.
# Phase 3b: the issuer picker ("Other..." adds an issuer, IssuerChoice) and the verification code
# and link are part of the proposal. The authenticity panel's buttons belong to the review form and
# post to check, which saves the edits first, so the check uses what the reviewer typed.
class ImportReviewsController < ApplicationController
  include IssuerChoice
  include TypeChoice

  require_role :editor

  INDEX_LIMIT = 200
  REVIEW_FIELDS = %i[crew_member_id certificate_type_id other_type_name completed_on expires_on no_expiration certificate_number issued_by
    certificate_issuer_id other_issuer_name verification_code verification_url].freeze
  # Saved edits to these re-run the item's authenticity check (Verification::Run compares them).
  VERIFICATION_ATTRIBUTES = %w[matched_certificate_issuer_id issuer_match proposed_verification_code proposed_verification_url
    matched_crew_member_id proposed_completed_on proposed_expires_on proposed_expires_on_source].freeze
  # Left out of an accept or merge while they are still the item's own proposal (accept_attributes).
  VERIFICATION_FIELDS = %i[certificate_issuer_id verification_code verification_url].freeze
  CREW_MEMBER_FIELDS = %i[first_name last_name employer crew_role_id].freeze

  # The reviewer's version of the proposal (form scope :review).
  Fields = Struct.new(*REVIEW_FIELDS, keyword_init: true)

  before_action :set_item, except: %i[index accept_all]
  before_action :require_reviewable, except: %i[index accept_all reread]

  def index
    queue = ImportItem.review_queue
    @total_count = queue.count
    @skipped_count = queue.where.not(skipped_at: nil).count
    @items = queue.limit(INDEX_LIMIT).includes(:matched_crew_member, :matched_certificate_type).to_a
    @processing_count = ImportItem.in_pipeline.count
    @blockers = @items.to_h { |item| [ item.id, Imports::AcceptAll.blockers(item) ] }
    @ready_count = @blockers.values.count(&:empty?)
  end

  # Accepts everything in the queue a person needn't look at (Imports::AcceptAll).
  def accept_all
    result = Imports::AcceptAll.new(user: Current.user).call
    left = ImportItem.review_queue.count
    notice = "Accepted #{helpers.pluralize(result.accepted, "certificate")}."
    notice += " #{left} still #{left == 1 ? "needs" : "need"} a look." if left.positive?
    redirect_to import_reviews_path, status: :see_other, notice: notice
  end

  def show
    @fields = fields_from_item
    load_review
  end

  # Saves edits to the proposal without accepting; the item stays in the queue.
  def update
    @fields = fields_from_params
    problems = save_edits
    return render_review_errors(problems) if problems.any?

    check_item_later
    redirect_to import_review_path(@item), status: :see_other,
      notice: [ "Saved your edits. #{item_label} is still waiting for review.", reset_fake_sentence(@item), issuer_sentence, type_sentence ].compact.join(" ")
  end

  # The authenticity panel's buttons: saves the form's edits (as update does), then records a
  # person's result (authenticity[status], with authenticity[note]) or, without a status, runs
  # "Check again" (Verification::CheckJob with force), so the issuer, code and link checked are the
  # ones on screen. Check again replaces a person's result only if it was on the page shown
  # (authenticity[shown_at], AuthenticityChecksController.recheck_requested_at).
  def check
    @fields = fields_from_params
    status = params.dig(:authenticity, :status).to_s.presence
    return render_review_errors([ AuthenticityChecksController::CHOOSE_RESULT ]) if status && Authenticity::PERSON_STATUSES.exclude?(status)

    problems = save_edits
    return render_review_errors(problems) if problems.any?

    requested_at = AuthenticityChecksController.recheck_requested_at(params.dig(:authenticity, :shown_at))
    if status
      note = params.dig(:authenticity, :note).to_s.strip.first(AuthenticityChecksController::NOTE_LIMIT)
      @item.record_authenticity!(status: status, method: Authenticity::PERSON_METHOD, note: note, by: Current.user)
      notice = [ "Saved your edits and recorded “#{@item.authenticity_label}”.", AuthenticityChecksController.fake_hint(@item),
        AuthenticityChecksController::RECORDED_HINT ].compact.join(" ")
    elsif (newer = AuthenticityChecksController.newer_result_sentence(@item, requested_at))
      notice = "Saved your edits. #{newer}"
    else
      Verification::CheckJob.perform_later(@item, force: true, requested_at: requested_at)
      notice = "Saved your edits and checking again with them. #{AuthenticityChecksController::CHECKING_HINT}"
    end
    redirect_to import_review_path(@item, anchor: "authenticity"), status: :see_other, notice: [ notice, issuer_sentence, type_sentence ].compact.join(" ")
  end

  def accept
    @fields = fields_from_params
    return render_review_errors(issuer_problems) if issuer_problems.any?

    next_id = next_item_id
    certificate = Imports::Accept.new(@item, user: Current.user, attributes: accept_attributes).call
    redirect_to_next next_id, notice: [ "Accepted #{certificate.certificate_type.name} for #{certificate.crew_member.display_name}.",
      fake_sentence(certificate), issuer_sentence, type_sentence ].compact.join(" ")
  rescue Imports::Accept::NotReviewable => error
    redirect_to_next nil, alert: error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordInvalid => error
    render_review_errors(error.record.errors.full_messages)
  end

  def reject
    next_id = next_item_id
    Imports::Reject.new(@item, user: Current.user, reason: reject_reason).call
    redirect_to_next next_id, notice: "Rejected #{item_label}."
  rescue Imports::Accept::NotReviewable => error
    redirect_to_next nil, alert: error.record.errors.full_messages.to_sentence
  end

  def skip
    next_id = next_item_id
    @item.update!(skipped_at: Time.current)
    redirect_to_next next_id, notice: "Skipped #{item_label}; it moves to the end of the queue."
  end

  # Adds the card's holder to the crew, then comes back to this item with them picked. Someone
  # who may already be on the list (possible_duplicates) is only added with confirm_duplicate.
  def create_crew_member
    duplicates = possible_duplicates(crew_member_params)
    if duplicates.any? && params[:confirm_duplicate] != "1"
      return render_crew_member_errors([ "#{helpers.import_duplicate_members_sentence(duplicates)} " \
                                         "Tick \"Yes, this is someone else\" to add another person anyway." ])
    end

    crew_member = Imports::CreateCrewMember.new(@item, user: Current.user, attributes: crew_member_params).call
    check_item_later # the holder compared is someone else now
    redirect_to import_review_path(@item), status: :see_other,
      notice: [ "Added #{crew_member.display_name} to the crew and picked them for this certificate.", reset_fake_sentence(@item) ].compact.join(" ")
  rescue Imports::Accept::NotReviewable => error
    redirect_to_next nil, alert: error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordInvalid => error
    render_crew_member_errors(error.record.errors.full_messages)
  end

  # Front and back photos of one card: one certificate holding every item's file.
  def merge
    @fields = fields_from_params
    return render_review_errors(issuer_problems) if issuer_problems.any?

    others = merge_others
    if others.empty?
      return render_review_errors([ "The matching items were reviewed in the meantime, so there is nothing left to merge." ])
    end

    next_id = next_item_id(also_leaving: others.map(&:id))
    certificate = Imports::Merge.new(@item, others: others, user: Current.user, attributes: accept_attributes).call
    redirect_to_next next_id, notice: [ "Merged #{helpers.pluralize(others.size + 1, "file")} into one " \
      "#{certificate.certificate_type.name} certificate for #{certificate.crew_member.display_name}.", fake_sentence(certificate),
      issuer_sentence, type_sentence ].compact.join(" ")
  rescue ActiveRecord::RecordInvalid => error # includes Imports::Accept::NotReviewable for a partner reviewed meanwhile
    render_review_errors(error.record.errors.full_messages)
  end

  # Sends the whole file through the pipeline again (a needs_review item from the review
  # screen, a rejected or failed one from the batch page); it uses some of the day's AI
  # allocation. Imports::Reread decides what may be read again.
  def reread
    Imports::Reread.new(@item, user: Current.user).call
    redirect_to import_path(@item.import_batch_id), status: :see_other,
      notice: "Reading #{@item.original_filename.presence || "item #{@item.id}"} again."
  rescue Imports::Reread::NotAllowed => error
    redirect_back_or_to import_path(@item.import_batch_id), alert: error.message, status: :see_other
  end

  private
    def set_item
      @item = ImportItem.includes(:matched_crew_member, :matched_certificate_type, :matched_certificate_issuer, :authenticity_checked_by)
        .with_attached_file.find(params.expect(:id))
    end

    # Someone else may have reviewed it since the link was rendered.
    def require_reviewable
      return if @item.needs_review?

      message = "#{item_label} is no longer waiting for review (#{helpers.import_item_status_label(@item).downcase})."
      if request.get? || request.head? # HEAD is routed like GET
        redirect_to import_path(@item.import_batch_id), notice: message
      else
        redirect_to_next nil, alert: message
      end
    end

    # Items ahead of / behind item in ImportItem.review_queue's order (skipped_at NULLS FIRST, id).
    def queue_before(item)
      if item.skipped_at
        ImportItem.review_queue.where("import_items.skipped_at IS NULL OR import_items.skipped_at < :at OR " \
                                      "(import_items.skipped_at = :at AND import_items.id < :id)", at: item.skipped_at, id: item.id)
      else
        ImportItem.review_queue.where("import_items.skipped_at IS NULL AND import_items.id < ?", item.id)
      end
    end

    def queue_after(item)
      if item.skipped_at
        ImportItem.review_queue.where("import_items.skipped_at > :at OR (import_items.skipped_at = :at AND import_items.id > :id)",
          at: item.skipped_at, id: item.id)
      else
        ImportItem.review_queue.where("import_items.skipped_at IS NOT NULL OR import_items.id > ?", item.id)
      end
    end

    # Chosen before the action changes the queue: the item after this one, else the first.
    def next_item_id(also_leaving: [])
      leaving = [ @item.id, *also_leaving ]
      queue_after(@item).where.not(id: leaving).pick(:id) || ImportItem.review_queue.where.not(id: leaving).pick(:id)
    end

    # messages: notice: and/or alert: for the flash.
    def redirect_to_next(candidate_id, **messages)
      next_id = candidate_id if candidate_id && ImportItem.review_queue.exists?(candidate_id)
      next_id ||= ImportItem.review_queue.where.not(id: @item.id).pick(:id)

      if next_id
        redirect_to import_review_path(next_id), status: :see_other, **messages
      else
        notice = [ messages[:notice], "Nothing else is waiting for review." ].compact.join(" ")
        redirect_to import_reviews_path, status: :see_other, **messages, notice: notice
      end
    end

    def render_review_errors(messages)
      @errors = messages
      load_review
      render :show, status: :unprocessable_entity
    end

    def render_crew_member_errors(messages)
      @fields = fields_from_item
      @crew_member_errors = messages
      @crew_member_attributes = crew_member_params
      load_review
      render :show, status: :unprocessable_entity
    end

    # Everything the review screen shows besides the item and @fields.
    def load_review
      @queue_count = ImportItem.review_queue.count
      @queue_position = queue_before(@item).count + 1
      @merge_candidates = Imports::MergeCandidates.for(@item).to_a
      @crew_members = CrewMember.active.ordered.to_a
      @certificate_types = CertificateType.active.ordered.to_a
      @certificate_issuers = CertificateIssuer.active.ordered.to_a
      @crew_roles = CrewRole.ordered.to_a
      @employers = CrewMember.employer_names
      @crew_member_attributes ||= Imports::CreateCrewMember.suggested_attributes(@item)
      @crew_member_duplicates = possible_duplicates(@crew_member_attributes)
    end

    # People a crew member created from this item may repeat: the person it is already matched
    # to (exactly, or picked by hand) and any member, active or not, whose name, preferred name
    # or alias is the name entered, or that name with or without a middle name
    # (CrewMember.matching_normalized_name and matching_name_ignoring_middle, active first). Someone
    # who left and came back is better reactivated than added a second time.
    def possible_duplicates(attributes)
      attributes = attributes.to_h.symbolize_keys
      name = [ attributes[:first_name], attributes[:last_name] ].compact_blank.join(" ")
      matched = @item.matched_crew_member if @item.person_matched? || @item.person_picked?
      [ matched, *CrewMember.matching_normalized_name(name), *CrewMember.matching_name_ignoring_middle(name) ].compact.uniq
    end

    # The form starts from the proposal. A computed expiry is left blank: blank means
    # "work it out from the type", which then follows the reviewer's choice of type. A printed
    # or typed (manual) one is filled in.
    def fields_from_item
      given = @item.proposed_expires_on.present? && !@item.proposed_expiry_computed? && !@item.proposed_expiry_none?
      Fields.new(
        crew_member_id: @item.matched_crew_member_id,
        certificate_type_id: @item.matched_certificate_type_id,
        completed_on: @item.proposed_completed_on&.iso8601,
        expires_on: (@item.proposed_expires_on.iso8601 if given),
        no_expiration: @item.proposed_expiry_no_expiration?,
        certificate_number: @item.proposed_certificate_number,
        issued_by: @item.issuer_raw,
        certificate_issuer_id: @item.matched_certificate_issuer_id,
        verification_code: @item.proposed_verification_code,
        verification_url: @item.proposed_verification_url
      )
    end

    # Every field is passed on to Imports::Accept / Merge: a blank one clears the proposal
    # (a blank expiry is derived from the type), an untouched printed expiry stays printed.
    def fields_from_params
      Fields.new(**params.expect(review: REVIEW_FIELDS).to_h.symbolize_keys).tap do |fields|
        fields.other_issuer_name = fields.other_issuer_name.to_s.squish.presence
        fields.other_type_name = fields.other_type_name.to_s.squish.presence
      end
    end

    # The issuer and type pickers' problems.
    def issuer_problems
      @issuer_problems ||= issuer_choice_problems(issuer_id: @fields.certificate_issuer_id, other_name: @fields.other_issuer_name,
        verification_url: @fields.verification_url.to_s.strip) +
        type_choice_problems(type_id: @fields.certificate_type_id, other_name: @fields.other_type_name)
    end

    # The chosen type, or nil for none. "Other..." finds or creates it from the typed name.
    def chosen_type
      return CertificateType.find_by(id: @fields.certificate_type_id.presence) unless other_type_chosen?(@fields.certificate_type_id)

      @chosen_type = CertificateType.find_or_create_from_name!(@fields.other_type_name)
    end

    def proposed_dates(type)
      no_expiration = ActiveModel::Type::Boolean.new.cast(@fields.no_expiration)
      Imports::DateRules.new(completed_on: @fields.completed_on, expires_on: (@fields.expires_on unless no_expiration),
        no_expiration: no_expiration, certificate_type: type).call
    end

    # Saves the form's edits to the proposal (update and check). Returns the problems that kept it
    # from saving; nothing is saved then, and no issuer is added.
    def save_edits
      member = CrewMember.find_by(id: @fields.crew_member_id.presence)
      problems = proposed_dates(nil).errors + issuer_problems
      return problems if problems.any?

      with_chosen_issuer(@fields.certificate_issuer_id, @fields.other_issuer_name) do |issuer|
        @chosen_issuer = issuer
        type = chosen_type
        @item.update!(proposal_attributes(member, type, proposed_dates(type), issuer))
      end
      []
    end

    # The fields for Imports::Accept / Merge, with the issuer picker's choice resolved to an id.
    # The issuer, code and link are left out while they are still the item's own proposal, so
    # Imports::Accept takes them from the items: in a merge, from the first that has them (the
    # back of a card often carries the QR code), rather than this item's blanks. An issuer added
    # with "Other..." stays if the accept then fails (the form offers the same name again, which
    # finds it): Accept enqueues jobs, so it isn't wrapped in a transaction.
    def accept_attributes
      @chosen_issuer = chosen_issuer(@fields.certificate_issuer_id, @fields.other_issuer_name)
      attributes = @fields.to_h.except(:other_issuer_name, :other_type_name)
        .merge(certificate_issuer_id: @chosen_issuer&.id, certificate_type_id: chosen_type&.id)
      proposal = fields_from_item
      attributes.except(*VERIFICATION_FIELDS.select { |field| unchanged_verification_field?(field, attributes[field], proposal[field]) })
    end

    def unchanged_verification_field?(field, value, proposed)
      case field
      when :certificate_issuer_id then value.presence&.to_i == proposed
      when :verification_code then value.to_s.squish.presence == proposed
      when :verification_url then Certificate.normalize_verification_url(value) == proposed
      end
    end

    # An accepted item keeps the check a person recorded on it (Imports::Accept), so a confirmed
    # fake one becomes a certificate that counts as not valid, or history when a genuine one of
    # its type is on file (Certificate's currency rule).
    def fake_sentence(certificate)
      return reset_fake_sentence(certificate) unless certificate.authenticity_confirmed_fake?
      if certificate.superseded?
        return "It is confirmed fake, so it is kept as history: another #{certificate.certificate_type.name} certificate on file is the current one."
      end

      "It is confirmed fake, so it counts as not valid in compliance and is left out of packets."
    end

    # A person's Not found or Doesn't match that this save turned back into needs_check, since its
    # details changed (Authenticity), says so.
    def reset_fake_sentence(record)
      record.authenticity_note if record.authenticity_reset_by_last_save?
    end

    # What the notice says about a type chosen with "Other..." (TypeChoice#other_type_sentence).
    def type_sentence
      other_type_sentence(@chosen_type, @fields.other_type_name) if @chosen_type
    end

    # What the notice says about an issuer chosen with "Other..." (IssuerChoice#other_issuer_sentence).
    def issuer_sentence
      other_issuer_sentence(@chosen_issuer, @fields.other_issuer_name) if other_issuer_chosen?(@fields.certificate_issuer_id, @fields.other_issuer_name)
    end

    # Saved edits. The matcher's proposed person keeps its verdict (matched or suggested). A
    # person picked by hand is saved with person_match :picked ("Picked by hand" on screen),
    # so Imports::Accept never takes the pick for the matcher's proposal and teaches that
    # person a name the AI may have misread; clearing the person saves :unmatched. A type
    # picked by hand counts as matched (types learn nothing from a review). The pipeline's
    # date problems (error_message) are cleared: the dates saved here passed Imports::DateRules.
    # The issuer saved here counts as matched, like a type, even when it is the suggestion the
    # form showed: saving it confirms it, so Verification::Run trusts it with an automatic check.
    def proposal_attributes(member, type, dates, issuer)
      attributes = {
        proposed_completed_on: dates.completed_on,
        proposed_expires_on: dates.expires_on,
        proposed_expires_on_source: saved_expiry_source(dates),
        proposed_certificate_number: @fields.certificate_number,
        issuer_raw: @fields.issued_by.to_s.squish.presence,
        proposed_verification_code: @fields.verification_code,
        proposed_verification_url: @fields.verification_url,
        error_message: nil
      }
      if member&.id != @item.matched_crew_member_id
        attributes.merge!(matched_crew_member: member, person_match: member ? :picked : :unmatched)
      end
      if type&.id != @item.matched_certificate_type_id
        attributes.merge!(matched_certificate_type: type, type_match: type ? :matched : :unmatched)
      end
      if issuer&.id != @item.matched_certificate_issuer_id || (issuer && !@item.issuer_matched?)
        attributes.merge!(matched_certificate_issuer: issuer, issuer_match: issuer ? :matched : :unmatched)
      end
      attributes
    end

    # A saved change to what the check compares (the issuer or its confirmation, code, link, person
    # or dates) checks the item again (network checks in the job).
    def check_item_later
      Verification::CheckJob.perform_later(@item) if VERIFICATION_ATTRIBUTES.any? { @item.saved_change_to_attribute?(it) }
    end

    # DateRules calls any expiry it is given printed. It keeps the item's source (printed, or
    # worked out from a printed period) only when it is that same date; any other date is one
    # the reviewer typed: manual.
    def saved_expiry_source(dates)
      return dates.expires_on_source unless dates.expires_on_source == :printed
      return :manual unless dates.expires_on == @item.proposed_expires_on

      @item.proposed_expiry_printed? || @item.proposed_expiry_printed_period? ? @item.proposed_expires_on_source.to_sym : :manual
    end

    # Only items the screen offered (and that still match) are merged.
    def merge_others
      ids = Array(params[:other_ids]).grep(String).map(&:to_i)
      Imports::MergeCandidates.for(@item).where(id: ids).to_a
    end

    def reject_reason
      params.expect(reject: [ :reason ])[:reason]
    rescue ActionController::ParameterMissing
      nil
    end

    def crew_member_params
      params.expect(crew_member: CREW_MEMBER_FIELDS).to_h.symbolize_keys
    end

    def item_label
      [ @item.original_filename.presence || "Item #{@item.id}", helpers.import_page_label(@item) ].compact.join(" ")
    end
end
