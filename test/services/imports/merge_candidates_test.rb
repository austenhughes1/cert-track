require "test_helper"
require_relative "match_test_support"

class Imports::MergeCandidatesTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  test "finds other review items with the same person, type and number, in any batch" do
    front = review_item
    other_batch = ImportBatch.create!(uploaded_by: users(:admin), status: :needs_review)
    back = review_item(import_batch: other_batch, original_filename: "back.jpg")
    review_item(proposed_certificate_number: "30-0000002")                  # other number
    review_item(member: crew_members(:li_chen))                              # other person
    review_item(type: certificate_types(:flagger))                           # other type
    review_item(status: :accepted)                                           # not in the queue

    assert_equal [ back ], Imports::MergeCandidates.for(front).to_a
    assert_equal [ front ], Imports::MergeCandidates.for(back).to_a
  end

  test "matches suggested people and types too" do
    front = review_item(person_match: :suggested, type_match: :suggested)
    back = review_item

    assert_equal [ back ], Imports::MergeCandidates.for(front).to_a
  end

  test "nothing without a person, type or number" do
    review_item
    assert_empty Imports::MergeCandidates.for(review_item(proposed_certificate_number: nil))
    assert_empty Imports::MergeCandidates.for(review_item(member: nil))
    assert_empty Imports::MergeCandidates.for(review_item(type: nil))
  end
end
