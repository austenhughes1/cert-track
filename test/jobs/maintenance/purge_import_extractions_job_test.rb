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

  test "is scheduled nightly in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "purge_import_extractions")

    assert_equal Maintenance::PurgeImportExtractionsJob, entry["class"].safe_constantize
    assert_instance_of Fugit::Cron, Fugit.parse(entry["schedule"], multi: :fail)
  end
end
