require "test_helper"
require_relative "file_copy_test_support"

class Backups::FileCopyStatusTest < ActiveSupport::TestCase
  include FileCopyTestSupport

  setup { travel_to Time.zone.local(2026, 11, 4, 9, 0) }

  test "says nothing while copies are off" do
    status = with_env("FILE_COPY_DIR" => nil) { Backups::FileCopyStatus.current }

    assert_not status.configured?
    assert_not status.needs_attention?
  end

  test "a fresh folder with no run yet needs no attention" do
    status = Backups::FileCopyStatus.new(@store)

    assert_nil status.last_run
    assert_not status.stale?
    assert_not status.needs_attention?
  end

  test "a missing or read-only folder needs attention" do
    assert_equal :missing, Backups::FileCopyStatus.new(Backups::FileCopyStore.new(File.join(@copy_dir, "gone"))).folder_problem
    assert Backups::FileCopyStatus.new(Backups::FileCopyStore.new(File.join(@copy_dir, "gone"))).needs_attention?
  end

  test "a complete copy in the last two days needs no attention" do
    record_run(finished_at: 2.days.ago + 1.minute, outcome: "complete")

    status = Backups::FileCopyStatus.new(@store)

    assert_equal Time.zone.local(2026, 11, 2, 9, 1), status.last_success_at
    assert_not status.needs_attention?
  end

  test "no complete copy for over two days is stale" do
    record_run(finished_at: 1.hour.ago, outcome: "incomplete", last_success_at: 2.days.ago - 1.minute, failed: 3)

    status = Backups::FileCopyStatus.new(@store)

    assert status.stale?
    assert_equal 3, status.failed
    assert status.needs_attention?
  end

  test "runs that never completed are stale" do
    record_run(finished_at: 1.hour.ago, outcome: "incomplete", last_success_at: nil)

    assert Backups::FileCopyStatus.new(@store).stale?
  end

  test "a run that stopped for space, or a disk under the reserve, is low on space" do
    record_run(finished_at: 1.hour.ago, outcome: "low_space")
    assert Backups::FileCopyStatus.new(@store).low_space?

    record_run(finished_at: 1.hour.ago, outcome: "complete", free_bytes: 4.gigabytes, reserve_bytes: 5.gigabytes)
    status = Backups::FileCopyStatus.new(@store)
    assert status.low_space?
    assert status.needs_attention?
  end

  test "inventory counts kept files, copies and the trash from the database and the folder" do
    certificate = certificates(:juan_osha30)
    copied = certificate_blob(certificate)
    trashed = certificate_blob(certificate)
    run_copy
    certificate.files.find_by!(blob_id: trashed.id).purge
    run_copy
    waiting = certificate_blob(certificate)

    inventory = Backups::FileCopyStatus.new(@store).inventory

    assert_equal [ 2, copied.byte_size + waiting.byte_size ], [ inventory.kept, inventory.kept_bytes ]
    assert_equal [ 1, copied.byte_size ], [ inventory.copied, inventory.copied_bytes ]
    assert_equal [ 1, trashed.byte_size, [ Date.current ] ], [ inventory.trash_files, inventory.trash_bytes, inventory.trash_days ]
  end
end
