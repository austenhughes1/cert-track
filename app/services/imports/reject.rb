module Imports
  # The reviewer's Reject: the item becomes rejected and never turns into a certificate.
  #
  #   Imports::Reject.new(item, user: Current.user, reason: "Not a certificate").call # => item
  #
  # Only needs_review items can be rejected (else Imports::Accept::NotReviewable, a
  # RecordInvalid). Records the reason (DEFAULT_REASON when blank), reviewed_by and
  # reviewed_at, then runs the batch's check_completion!.
  class Reject
    DEFAULT_REASON = "Rejected by reviewer".freeze

    def initialize(item, user:, reason: nil)
      @item = item
      @user = user
      @reason = reason.to_s.squish.truncate(255).presence || DEFAULT_REASON
    end

    def call
      ImportItem.transaction do
        Imports::Accept.lock_for_review!(@item)
        @item.update!(status: :rejected, rejection_reason: @reason, reviewed_by: @user, reviewed_at: Time.current)
      end

      @item.import_batch.check_completion!
      @item
    end
  end
end
