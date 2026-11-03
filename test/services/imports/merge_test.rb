require "test_helper"
require_relative "match_test_support"

class Imports::MergeTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  test "front and back become one certificate with both files" do
    front = review_item(holder_name_raw: "Juan Ortiz")
    back = review_item(original_filename: "back.jpg", holder_name_raw: "Jaun Ortis", person_match: :suggested)
    back.file.attach(io: StringIO.new(file_fixture("certificate.png").binread), filename: "back.png", content_type: "image/png")

    certificate = Imports::Merge.new(front, others: Imports::MergeCandidates.for(front), user: users(:manager)).call

    assert_equal [ front.file.blob, back.file.blob ], certificate.files.blobs.to_a
    assert_equal front, certificate.import_item
    [ front, back ].each do |item|
      item.reload
      assert item.accepted?
      assert_equal certificate, item.certificate
      assert_equal users(:manager), item.reviewed_by
    end
    assert_equal [ front, back ].sort_by(&:id), certificate.import_items.order(:id).to_a
    assert_includes crew_members(:juan_ortiz).reload.name_aliases, "Jaun Ortis"
  end

  test "attributes apply to the merged certificate" do
    front = review_item
    back = review_item

    certificate = Imports::Merge.new(front, others: [ back ], user: users(:manager), attributes: { certificate_number: "30-7777777" }).call

    assert_equal "30-7777777", certificate.certificate_number
  end

  test "items in other batches update their batch too" do
    other_batch = ImportBatch.create!(uploaded_by: users(:admin), status: :needs_review, summary_sent_at: 1.hour.ago)
    front = review_item
    back = review_item(import_batch: other_batch)

    Imports::Merge.new(front, others: [ back ], user: users(:manager)).call

    assert other_batch.reload.completed?
  end

  test "every item must be in the review queue; nothing changes otherwise" do
    front = review_item
    back = review_item(status: :rejected)

    assert_no_difference -> { Certificate.count } do
      assert_raises(Imports::Accept::NotReviewable) { Imports::Merge.new(front, others: [ back ], user: users(:manager)).call }
    end
    assert front.reload.needs_review?
  end

  test "needs at least one other item" do
    front = review_item

    error = assert_raises(Imports::Accept::NotReviewable) { Imports::Merge.new(front, others: [ front ], user: users(:manager)).call }
    assert_equal [ "Choose at least one other item to merge with this one." ], error.record.errors.full_messages
  end

  test "a file shared by two items is attached once" do
    front = review_item
    back = review_item
    back.file.attach(front.file.blob)

    certificate = Imports::Merge.new(front, others: [ back ], user: users(:manager)).call

    assert_equal 1, certificate.files.count
  end
end
