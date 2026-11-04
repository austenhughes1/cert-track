# The import review queue (docs/PLAN.md, "Bulk import pipeline", step 10): one screen per
# item, the file on the left and the AI's proposal on the right, editable. Accept, reject,
# skip, "create crew member from this" and front/back merge go through the Imports::* review
# services (which also run the batch's check_completion!); after each the reviewer moves on
# to the next item. "Read again" (Imports::Reread) also takes rejected and failed items, from
# the batch page. Editors only: the queue shows personal data from the cards.
class ImportReviewsController < ApplicationController
  require_role :editor

  INDEX_LIMIT = 200
  REVIEW_FIELDS = %i[crew_member_id certificate_type_id completed_on expires_on certificate_number issued_by].freeze
  CREW_MEMBER_FIELDS = %i[first_name last_name employer crew_role_id].freeze

  # The reviewer's version of the proposal (form scope :review).
  Fields = Struct.new(*REVIEW_FIELDS, keyword_init: true)

  before_action :set_item, except: :index
  before_action :require_reviewable, except: %i[index reread]

  def index
    queue = ImportItem.review_queue
    @total_count = queue.count
    @skipped_count = queue.where.not(skipped_at: nil).count
    @items = queue.limit(INDEX_LIMIT).includes(:matched_crew_member, :matched_certificate_type).to_a
    @processing_count = ImportItem.in_pipeline.count
  end

  def show
    @fields = fields_from_item
    load_review
  end

  # Saves edits to the proposal without accepting; the item stays in the queue.
  def update
    @fields = fields_from_params
    member = CrewMember.find_by(id: @fields.crew_member_id.presence)
    type = CertificateType.find_by(id: @fields.certificate_type_id.presence)
    dates = Imports::DateRules.new(completed_on: @fields.completed_on, expires_on: @fields.expires_on, certificate_type: type).call
    return render_review_errors(dates.errors) if dates.errors?

    @item.update!(proposal_attributes(member, type, dates))
    redirect_to import_review_path(@item), notice: "Saved your edits. #{item_label} is still waiting for review.", status: :see_other
  end

  def accept
    @fields = fields_from_params
    next_id = next_item_id
    certificate = Imports::Accept.new(@item, user: Current.user, attributes: @fields.to_h).call
    redirect_to_next next_id, notice: "Accepted #{certificate.certificate_type.name} for #{certificate.crew_member.display_name}."
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
    redirect_to import_review_path(@item), status: :see_other,
      notice: "Added #{crew_member.display_name} to the crew and picked them for this certificate."
  rescue Imports::Accept::NotReviewable => error
    redirect_to_next nil, alert: error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordInvalid => error
    render_crew_member_errors(error.record.errors.full_messages)
  end

  # Front and back photos of one card: one certificate holding every item's file.
  def merge
    @fields = fields_from_params
    others = merge_others
    if others.empty?
      return render_review_errors([ "The matching items were reviewed in the meantime, so there is nothing left to merge." ])
    end

    next_id = next_item_id(also_leaving: others.map(&:id))
    certificate = Imports::Merge.new(@item, others: others, user: Current.user, attributes: @fields.to_h).call
    redirect_to_next next_id, notice: "Merged #{helpers.pluralize(others.size + 1, "file")} into one " \
                                      "#{certificate.certificate_type.name} certificate for #{certificate.crew_member.display_name}."
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
      @item = ImportItem.includes(:matched_crew_member, :matched_certificate_type).with_attached_file.find(params.expect(:id))
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
      @crew_roles = CrewRole.ordered.to_a
      @employers = CrewMember.employer_names
      @crew_member_attributes ||= Imports::CreateCrewMember.suggested_attributes(@item)
      @crew_member_duplicates = possible_duplicates(@crew_member_attributes)
    end

    # People a crew member created from this item may repeat: the person it is already matched
    # to (exactly, or picked by hand) and any member, active or not, whose name, preferred name
    # or alias is the name entered (CrewMember.matching_normalized_name, active first). Someone
    # who left and came back is better reactivated than added a second time.
    def possible_duplicates(attributes)
      attributes = attributes.to_h.symbolize_keys
      name = [ attributes[:first_name], attributes[:last_name] ].compact_blank.join(" ")
      matched = @item.matched_crew_member if @item.person_matched? || @item.person_picked?
      [ matched, *CrewMember.matching_normalized_name(name) ].compact.uniq
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
        certificate_number: @item.proposed_certificate_number,
        issued_by: @item.issuer_raw
      )
    end

    # Every field is passed on to Imports::Accept / Merge: a blank one clears the proposal
    # (a blank expiry is derived from the type), an untouched printed expiry stays printed.
    def fields_from_params
      Fields.new(**params.expect(review: REVIEW_FIELDS).to_h.symbolize_keys)
    end

    # Saved edits. The matcher's proposed person keeps its verdict (matched or suggested). A
    # person picked by hand is saved with person_match :picked ("Picked by hand" on screen),
    # so Imports::Accept never takes the pick for the matcher's proposal and teaches that
    # person a name the AI may have misread; clearing the person saves :unmatched. A type
    # picked by hand counts as matched (types learn nothing from a review). The pipeline's
    # date problems (error_message) are cleared: the dates saved here passed Imports::DateRules.
    def proposal_attributes(member, type, dates)
      attributes = {
        proposed_completed_on: dates.completed_on,
        proposed_expires_on: dates.expires_on,
        proposed_expires_on_source: saved_expiry_source(dates),
        proposed_certificate_number: @fields.certificate_number,
        issuer_raw: @fields.issued_by.to_s.squish.presence,
        error_message: nil
      }
      if member&.id != @item.matched_crew_member_id
        attributes.merge!(matched_crew_member: member, person_match: member ? :picked : :unmatched)
      end
      if type&.id != @item.matched_certificate_type_id
        attributes.merge!(matched_certificate_type: type, type_match: type ? :matched : :unmatched)
      end
      attributes
    end

    # DateRules calls any expiry it is given printed. It stays printed only when it is the
    # date the AI read off the card; any other date is one the reviewer typed: manual.
    def saved_expiry_source(dates)
      return dates.expires_on_source unless dates.expires_on_source == :printed

      @item.proposed_expiry_printed? && dates.expires_on == @item.proposed_expires_on ? :printed : :manual
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
