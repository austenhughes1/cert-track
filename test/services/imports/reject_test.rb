require "test_helper"
require_relative "match_test_support"

class Imports::RejectTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  test "rejects a review item with the reason and reviewer" do
    item = review_item

    freeze_time do
      assert_equal item, Imports::Reject.new(item, user: users(:admin), reason: "  Blurry   photo ").call
      assert_equal Time.current, item.reload.reviewed_at
    end

    assert item.rejected?
    assert_equal "Blurry photo", item.rejection_reason
    assert_equal users(:admin), item.reviewed_by
    assert_nil item.certificate
  end

  test "a blank reason gets the default" do
    item = review_item
    Imports::Reject.new(item, user: users(:manager), reason: " ").call

    assert_equal "Rejected by reviewer", item.reload.rejection_reason
  end

  test "only review-queue items can be rejected" do
    %i[accepted rejected duplicate failed extracting].each do |status|
      item = review_item(status:)

      assert_raises(Imports::Accept::NotReviewable, status.to_s) { Imports::Reject.new(item, user: users(:manager)).call }
      assert_equal status.to_s, item.reload.status
    end
  end

  test "updates the batch" do
    batch = ImportBatch.create!(uploaded_by: users(:manager), status: :needs_review, summary_sent_at: 1.hour.ago)
    item = review_item(import_batch: batch)

    Imports::Reject.new(item, user: users(:manager)).call

    assert batch.reload.completed?
    assert_equal 0, batch.review_count
  end
end
