require "test_helper"
require "fugit"

class Maintenance::PurgeOldPacketsJobTest < ActiveJob::TestCase
  setup do
    @old = projects(:closed_2390)
    @fresh = projects(:tower_2417)
  end

  test "deletes zips built more than 7 days ago and keeps newer ones, every build record and index PDF" do
    travel_to 8.days.ago do
      Compliance::PacketBuilder.new(@old).attach!(built_by: users(:viewer))
    end
    travel_to 6.days.ago do
      Compliance::PacketBuilder.new(@fresh).attach!
    end
    old_zip = @old.reload.packet.blob
    old_built_at = @old.packet_built_at
    index_blobs = PacketBuild.all.map { |build| build.index_pdf.blob }

    count = nil
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { count = Maintenance::PurgeOldPacketsJob.perform_now }

    assert_equal 1, count
    assert_not @old.reload.packet.attached?
    assert_not ActiveStorage::Blob.exists?(old_zip.id)
    assert @old.packet_expired?
    assert_equal old_built_at, @old.packet_built_at
    assert @fresh.reload.packet.attached?

    assert_equal 2, PacketBuild.count
    assert_equal users(:viewer), @old.packet_builds.sole.built_by
    index_blobs.each { |blob| assert ActiveStorage::Blob.exists?(blob.id), "index PDF #{blob.filename} kept" }
  end

  test "a zip is kept through the day the packet page shows, whatever time it was built" do
    [ [ 0, 5 ], [ 2, 0 ], [ 3, 49 ], [ 3, 51 ], [ 15, 30 ], [ 23, 59 ] ].each do |hour, minute|
      travel_to Time.zone.local(2026, 11, 4, hour, minute) do
        Compliance::PacketBuilder.new(@fresh).attach!
      end
      kept_until = @fresh.reload.packet_kept_until
      assert_equal Date.new(2026, 11, 11), kept_until, "built at #{hour}:#{minute}"

      travel_to kept_until.in_time_zone.change(hour: 3, minute: 50) do # the nightly purge on that day
        assert_equal 0, Maintenance::PurgeOldPacketsJob.perform_now, "built at #{hour}:#{minute}, purged on its last day"
      end
      travel_to (kept_until + 1).in_time_zone.change(hour: 3, minute: 50) do
        assert_equal 1, Maintenance::PurgeOldPacketsJob.perform_now, "built at #{hour}:#{minute}, kept past its last day"
      end
      @fresh.packet.detach
    end
  end

  test "leaves other files alone, however old" do
    certificates(:juan_osha30).files.attach(io: StringIO.new("%PDF-1.4\n"), filename: "osha.pdf", content_type: "application/pdf")
    ActiveStorage::Attachment.update_all(created_at: 1.year.ago)

    assert_equal 0, Maintenance::PurgeOldPacketsJob.perform_now
    assert certificates(:juan_osha30).files.attached?
  end

  test "is scheduled nightly in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "purge_old_packets")

    assert_equal Maintenance::PurgeOldPacketsJob, entry["class"].safe_constantize
    cron = Fugit.parse(entry["schedule"], multi: :fail)
    assert_instance_of Fugit::Cron, cron
    assert_equal "America/Denver", cron.timezone.name
  end
end
