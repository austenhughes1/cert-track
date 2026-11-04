require "test_helper"
require "fugit"

class Maintenance::PurgeImportExtractionsJobTest < ActiveJob::TestCase
  test "clears extracted text from items reviewed more than 30 days ago" do
    stale = import_items(:accepted_li_flagger)
    stale.update_columns(reviewed_at: 31.days.ago)
    recent = import_items(:review_juan_first_aid) # still in the review queue

    assert_equal 1, Maintenance::PurgeImportExtractionsJob.perform_now

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

    assert_equal 2, Maintenance::PurgeImportExtractionsJob.perform_now

    assert_nil failed.reload.extracted_text
    assert_nil duplicate.reload.extracted_text
    assert_nil duplicate.extraction
    assert_not_nil review.reload.extracted_text
  end

  test "is scheduled nightly in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "purge_import_extractions")

    assert_equal Maintenance::PurgeImportExtractionsJob, entry["class"].safe_constantize
    assert_instance_of Fugit::Cron, Fugit.parse(entry["schedule"], multi: :fail)
  end
end
