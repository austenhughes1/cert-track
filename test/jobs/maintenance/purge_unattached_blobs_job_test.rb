require "test_helper"
require "fugit"

class Maintenance::PurgeUnattachedBlobsJobTest < ActiveJob::TestCase
  def create_blob(created_at:)
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.4 scan"), filename: "scan.pdf",
      content_type: "application/pdf").tap { |blob| blob.update_columns(created_at: created_at) }
  end

  test "purges unattached blobs older than the grace period and keeps the rest" do
    abandoned = create_blob(created_at: 3.days.ago)
    fresh = create_blob(created_at: 1.hour.ago)
    attached = create_blob(created_at: 10.days.ago)
    certificates(:juan_osha30).files.attach(attached)

    count = nil
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { count = Maintenance::PurgeUnattachedBlobsJob.perform_now }

    assert_equal 1, count
    assert_not ActiveStorage::Blob.exists?(abandoned.id)
    assert ActiveStorage::Blob.exists?(fresh.id)
    assert ActiveStorage::Blob.exists?(attached.id)
  end

  test "is scheduled nightly in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "purge_unattached_blobs")

    assert_equal Maintenance::PurgeUnattachedBlobsJob, entry["class"].safe_constantize
    cron = Fugit.parse(entry["schedule"], multi: :fail)
    assert_instance_of Fugit::Cron, cron
    assert_equal "America/Denver", cron.timezone.name
  end
end
