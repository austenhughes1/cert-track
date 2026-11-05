module Imports
  # Accepts several items as one certificate (the front and back of one card).
  #
  #   others = Imports::MergeCandidates.for(item)
  #   certificate = Imports::Merge.new(item, others:, user: Current.user, attributes: {}).call
  #
  # The certificate is built from item exactly as Imports::Accept does (attributes override
  # its fields) and carries every item's file, item's first. The issuer, verification code and
  # link may come from another item when item has none, and neither a person's confirmed fake
  # nor a flagged item's authenticity check is ever hidden (Imports::Accept). Every item becomes
  # accepted and points at it. All items must be in the review queue. Raises
  # ActiveRecord::RecordInvalid (NotReviewable for a status problem, or when there is nothing to
  # merge).
  class Merge
    def initialize(item, others:, user:, attributes: {})
      @item = item
      @others = Array(others).reject { |other| other.id == item.id }.uniq(&:id)
      @user = user
      @attributes = attributes
    end

    def call
      if @others.empty?
        @item.errors.add(:base, "Choose at least one other item to merge with this one.")
        raise Imports::Accept::NotReviewable.new(@item)
      end

      Imports::Accept.new(@item, user: @user, attributes: @attributes, merged_items: @others).call
    end
  end
end
