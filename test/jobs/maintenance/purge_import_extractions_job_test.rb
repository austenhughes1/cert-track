require "test_helper"
require "fugit"

class Maintenance::PurgeImportExtractionsJobTest < ActiveJob::TestCase
  test "clears extracted text from items reviewed more than 30 days ago" do
    stale = import_items(:accepted_li_flagger)
    stale.update_columns(reviewed_at: 31.days.ago)
    recent = import_items(:review_juan_first_aid) # still in the review queue

    assert_equal({ files: 0, uploads: 0, extractions: 1 }, Maintenance::PurgeImportExtractionsJob.perform_now)

    assert_nil stale.reload.extracted_text
    assert_nil stale.extraction
    assert_not_nil recent.reload.extracted_text
    assert_equal certificates(:li_flagger), stale.certificate
  end

  test "also clears failed and duplicate items, and leaves the review queue alone" do
    batch = import_batches(:march_batch)
    failed = batch.import_items.create!(status: :failed, sha256: "e" * 64, extracted_text: "DOB 1980-01-01",
      error_message: "AI extraction failed after 3 attempts")
    duplicate = import_items(:duplicate_li_flagger)
    duplicate.update_columns(extracted_text: "LI CHEN", extraction: { "certificates" => [] })
    review = import_items(:review_juan_first_aid)
    [ failed, duplicate, review ].each { |item| item.update_columns(updated_at: 45.days.ago) }

    assert_equal({ files: 0, uploads: 0, extractions: 2 }, Maintenance::PurgeImportExtractionsJob.perform_now)

    assert_nil failed.reload.extracted_text
    assert_nil duplicate.reload.extracted_text
    assert_nil duplicate.extraction
    assert_not_nil review.reload.extracted_text
  end

  test "deletes a failed item's file along with its text, and uploads still kept after 30 days" do
    batch = ImportBatch.create!(uploaded_by: users(:manager), status: :completed, created_at: 31.days.ago)
    batch.uploads.attach(io: StringIO.new("PK zip"), filename: "crew.zip", content_type: "application/zip")
    failed = batch.import_items.create!(status: :failed, sha256: "e" * 64, extracted_text: "DOB 1980-01-01",
      error_message: "AI extraction failed after 3 attempts",
      file: { io: StringIO.new("%PDF-1.4 cdl"), filename: "cdl.pdf", content_type: "application/pdf" })
    rejected = batch.import_items.create!(status: :rejected, sha256: "a" * 64, rejection_reason: "Not a certificate",
      reviewed_at: 31.days.ago, file: { io: StringIO.new("%PDF-1.4 outline"), filename: "outline.pdf", content_type: "application/pdf" })
    failed.update_columns(updated_at: 31.days.ago)

    counts = perform_enqueued_jobs { Maintenance::PurgeImportExtractionsJob.perform_now }

    assert_equal({ files: 1, uploads: 1, extractions: 1 }, counts)
    assert_not failed.reload.file.attached?
    assert_nil failed.extracted_text
    assert_not batch.reload.uploads.attached?
    assert rejected.reload.file.attached?, "a rejected file stays the original for duplicate detection"
    assert_equal [ rejected.file.blob ], ActiveStorage::Blob.all.to_a
  end

  test "is scheduled nightly in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "purge_import_extractions")

    assert_equal Maintenance::PurgeImportExtractionsJob, entry["class"].safe_constantize
    assert_instance_of Fugit::Cron, Fugit.parse(entry["schedule"], multi: :fail)
  end
end
