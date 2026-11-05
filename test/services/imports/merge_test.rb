require "test_helper"
require_relative "match_test_support"

class Imports::MergeTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  test "front and back become one certificate with both files" do
    front = review_item(holder_name_raw: "Juan Ortiz")
    back = review_item(original_filename: "back.jpg", holder_name_raw: "Jaun Ortis", person_match: :suggested)
    back.file.attach(io: StringIO.new(file_fixture("certificate.png").binread), filename: "back.png", content_type: "image/png")
    blobs = [ front.file.blob, back.file.blob ]

    certificate = Imports::Merge.new(front, others: Imports::MergeCandidates.for(front), user: users(:manager)).call

    assert_equal blobs, certificate.files_attachments.order(:id).map(&:blob), "item's file first"
    assert_equal front, certificate.import_item
    [ front, back ].each do |item|
      item.reload
      assert item.accepted?
      assert_equal certificate, item.certificate
      assert_equal users(:manager), item.reviewed_by
      assert_not item.file.attached?, "the certificate holds the file now"
    end
    assert_equal [ front, back ].sort_by(&:id), certificate.import_items.order(:id).to_a
    assert_includes crew_members(:juan_ortiz).reload.name_aliases, "Jaun Ortis"
  end

  test "the issuer, code and link may come from the back, and a flagged back's check is not hidden" do
    front = review_item(authenticity_status: :cannot_verify, authenticity_method: "rules")
    back = review_item(original_filename: "back.jpg", matched_certificate_issuer: issuer("REDCROSS"), issuer_match: :matched,
      proposed_verification_code: "TEST123", proposed_verification_url: "https://redcross-verify.com/c?certnumber=TEST123",
      authenticity_status: :suspicious, authenticity_method: "qr_link", authenticity_note: "The QR code points to a lookalike site.")

    certificate = Imports::Merge.new(front, others: [ back ], user: users(:manager)).call

    assert_equal [ issuer("REDCROSS"), "TEST123", "https://redcross-verify.com/c?certnumber=TEST123" ],
      [ certificate.certificate_issuer, certificate.verification_code, certificate.verification_url ]
    assert_equal [ "suspicious", "The QR code points to a lookalike site." ], [ certificate.authenticity_status, certificate.authenticity_note ]
  end

  test "a merge never hides a person's confirmed fake, even behind an automatic flag" do
    front = review_item(authenticity_status: :mismatch, authenticity_method: "automatic:national_osha_foundation")
    back = review_item(original_filename: "back.jpg")
    back.record_authenticity!(status: :not_found, method: "person", note: "Called the issuer: no such card", by: users(:admin))

    certificate = Imports::Merge.new(front, others: [ back ], user: users(:manager)).call

    assert_equal [ "not_found", "person", users(:admin) ],
      [ certificate.authenticity_status, certificate.authenticity_method, certificate.authenticity_checked_by ]
    assert certificate.authenticity_confirmed_fake?
    assert_equal "fake", certificate.compliance_status
  end

  test "a merge keeps the more conclusive check, and the front's own fields when it has them" do
    front = review_item(proposed_verification_code: "FRONT-1", authenticity_status: :needs_check, authenticity_method: "rules")
    back = review_item(proposed_verification_code: "BACK-1", authenticity_status: :verified, authenticity_method: "automatic:aha_ecards")

    certificate = Imports::Merge.new(front, others: [ back ], user: users(:manager)).call

    assert_equal [ "FRONT-1", "verified", "automatic:aha_ecards" ],
      [ certificate.verification_code, certificate.authenticity_status, certificate.authenticity_method ]
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
    blob = front.file.blob

    certificate = Imports::Merge.new(front, others: [ back ], user: users(:manager)).call

    assert_equal 1, certificate.files.count
    assert_equal [ certificate ], ActiveStorage::Attachment.where(blob_id: blob.id).map(&:record), "both items let go of it"
  end
end
