# The authenticity panel's actions (docs/PLAN.md, Phase 3b) for a certificate or an import item
# waiting for review: a person's result (Verified, Not found, Doesn't match, Can't be verified,
# with an optional note), which automatic checks leave alone, and "Check again", which runs
# Verification::CheckJob even over a person's result (one recorded before the page with the button
# was shown, authenticity[shown_at]: a result recorded after that, while the job waits included,
# stays). A person's Not found or Doesn't match makes
# it confirmed fake: the only result that counts it as not valid and leaves it out of packets.
# Admins and managers only. The review screen's panel posts to ImportReviewsController#check
# instead, which saves the review form's edits first; the import item routes here stay for a
# panel shown without that form.
#
#   PATCH /crew_members/:crew_member_id/certificates/:certificate_id/authenticity   authenticity[status], authenticity[note]
#   POST  /crew_members/:crew_member_id/certificates/:certificate_id/authenticity/recheck   authenticity[shown_at]
#   PATCH /imports/review/:import_item_id/authenticity                              (the same for an import item)
#   POST  /imports/review/:import_item_id/authenticity/recheck
class AuthenticityChecksController < ApplicationController
  NOTE_LIMIT = 1_000
  CHOOSE_RESULT = "Choose one of the result buttons to record a check.".freeze
  RECORDED_HINT = "Automatic checks won't change it unless someone runs Check again.".freeze
  CHECKING_HINT = "The result shows in this panel in a few seconds; reload the page to see it.".freeze
  NEWER_RESULT = "Someone recorded “%{label}” after this page was opened, so it wasn't checked again. Reload the page to see it.".freeze
  # After a person's Not found or Doesn't match (Authenticity#authenticity_confirmed_fake?).
  FAKE_HINT = "It is now confirmed fake: it counts as not valid in compliance and is left out of packets.".freeze
  FAKE_ITEM_HINT = "It is now confirmed fake: once accepted, it counts as not valid in compliance and is left out of packets.".freeze
  FAKE_HISTORY_HINT = "It is now confirmed fake and kept as history: another %{type} certificate on file is the current one.".freeze

  require_role :editor
  before_action :set_record

  def update
    result = params.expect(authenticity: %i[status note])
    status = result[:status].to_s
    unless Authenticity::PERSON_STATUSES.include?(status)
      return redirect_to @return_path, alert: CHOOSE_RESULT, status: :see_other
    end

    note = result[:note].to_s.strip.first(NOTE_LIMIT)
    @record.record_authenticity!(status: status, method: Authenticity::PERSON_METHOD, note: note, by: Current.user)
    redirect_to @return_path, status: :see_other, notice: [ "Recorded “#{@record.authenticity_label}”.", self.class.fake_hint(@record),
      RECORDED_HINT ].compact.join(" ")
  end

  def recheck
    requested_at = self.class.recheck_requested_at(params.dig(:authenticity, :shown_at))
    if (newer = self.class.newer_result_sentence(@record, requested_at))
      return redirect_to @return_path, status: :see_other, alert: newer
    end

    Verification::CheckJob.perform_later(@record, force: true, requested_at: requested_at)
    redirect_to @return_path, status: :see_other, notice: "Checking again. #{CHECKING_HINT}"
  end

  # Up to when "Check again" replaces a person's result: when the page it was pressed on was shown
  # (the panel's authenticity[shown_at]), so a result someone recorded after that, which the
  # clicker never saw, stays. Never later than now, which is also the time without a valid one.
  def self.recheck_requested_at(shown_at, now: Time.current)
    shown = Time.zone.iso8601(shown_at.to_s) if shown_at.present?
    [ shown, now ].compact.min
  rescue ArgumentError
    now
  end

  # Why "Check again" didn't run, when a person recorded the record's result after requested_at;
  # else nil. Verification::Run checks it again when the job runs.
  def self.newer_result_sentence(record, requested_at)
    at = record.authenticity_checked_at
    return unless record.authenticity_set_by_person? && at && at > requested_at

    format(NEWER_RESULT, label: record.authenticity_label)
  end

  # What a person's result means when it makes the record confirmed fake, else nil. A certificate
  # with a genuine one of its type on file is kept as history then (Certificate's currency rule).
  def self.fake_hint(record)
    return unless record.authenticity_confirmed_fake?
    return FAKE_ITEM_HINT if record.is_a?(ImportItem)

    record.superseded? ? format(FAKE_HISTORY_HINT, type: record.certificate_type.name) : FAKE_HINT
  end

  private
    def set_record
      if params.key?(:import_item_id)
        set_import_item
      else
        crew_member = CrewMember.find(params.expect(:crew_member_id))
        @record = crew_member.certificates.find(params.expect(:certificate_id))
        @return_path = crew_member_certificate_path(crew_member, @record, anchor: "authenticity")
      end
    end

    # Only while it waits for review: an accepted item's check lives on its certificate.
    def set_import_item
      @record = ImportItem.find(params.expect(:import_item_id))
      @return_path = import_review_path(@record, anchor: "authenticity")
      return if @record.needs_review?

      redirect_to import_path(@record.import_batch_id), status: :see_other,
        alert: "#{@record.original_filename.presence || "Item #{@record.id}"} is no longer waiting for review, so its check can't be changed here."
    end
end
