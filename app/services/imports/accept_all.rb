module Imports
  # "Accept all" on the review queue: accepts every item a person needn't look at. Ready means every
  # Imports::Decider rule holds (the person and type matched, the dates fine, nothing flagged, the
  # model's confidence at least Imports::Config.auto_accept_confidence, 85%), apart from auto-accept
  # being turned off. An item that may be the other side of another card is left for a person to merge.
  #
  #   Imports::AcceptAll.blockers(item) # => [] when ready, else why not
  #   result = Imports::AcceptAll.new(user: Current.user).call
  #   result.accepted # => 14
  #   result.skipped  # => 1, ready when asked but refused by Imports::Accept
  class AcceptAll
    Result = Data.define(:accepted, :skipped)
    MERGE_REASON = "It may be the other side of another card".freeze

    def self.blockers(item)
      reasons = Decider.new(item).blockers
      reasons += [ MERGE_REASON ] if reasons.empty? && MergeCandidates.for(item).exists?
      reasons
    end

    def self.ready_items(limit: nil)
      ImportItem.review_queue.limit(limit).includes(:matched_crew_member, :matched_certificate_type).select { |item| blockers(item).empty? }
    end

    def initialize(user:)
      @user = user
    end

    def call
      accepted = 0
      skipped = 0
      self.class.ready_items.each do |item|
        Accept.new(item, user: @user).call
        accepted += 1
      rescue Accept::NotReviewable, ActiveRecord::RecordInvalid => error
        skipped += 1
        Rails.logger.info("[Imports::AcceptAll] import item #{item.id} left for review: #{error.class.name}")
      end
      Result.new(accepted: accepted, skipped: skipped)
    end
  end
end
