require "test_helper"
require "rake"
require_relative "../services/backups/file_copy_test_support"

class FileCopiesTaskTest < ActiveSupport::TestCase
  include FileCopyTestSupport

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("certtrack:restore_files")
    @storage = ActiveStorage::Blob.service
  end

  test "certtrack:copy_files_now runs the copy inline and prints what it did" do
    blob = certificate_blob

    output = run_task("certtrack:copy_files_now")

    assert_match(/File copy complete: 1 copied \(\d+ Bytes\), 0 back from the trash, 0 failed, 0 of 1 not copied yet/, output)
    assert_includes output, "Free space: 60 GB (copying stops under 10 GB)"
    assert_equal blob.download, copied_bytes(blob)
  end

  test "certtrack:copy_files_now stops with the setup step when the folder is missing" do
    errors = run_task("certtrack:copy_files_now", dir: File.join(@copy_dir, "not-mounted"), aborts: true)

    assert_includes errors, "File copy failed: The file copy folder"
    assert_includes errors, Backups::FileCopyStore::SETUP_COMMAND
  end

  test "certtrack:restore_files is a dry run by default" do
    lost = certificate_blob
    certificate_blob
    run_copy
    @storage.delete(lost.key)

    output = run_task("certtrack:restore_files")

    assert_includes output, "Dry run, nothing uploaded (CONFIRM=1 uploads)"
    assert_match(/Blobs in the database\s+2$/, output)
    assert_match(/Still in storage\s+1$/, output)
    assert_match(/Missing from storage, would upload\s+1 \(0 from the trash\)$/, output)
    assert_not @storage.exist?(lost.key)
  end

  test "certtrack:restore_files CONFIRM=1 uploads the missing files" do
    lost = certificate_blob
    bytes = lost.download
    run_copy
    @storage.delete(lost.key)

    output = with_env("CONFIRM" => "1") { run_task("certtrack:restore_files") }

    assert_includes output, "Restoring files from #{@store.root}"
    assert_match(/Uploaded back to storage\s+1 \(0 from the trash\)$/, output)
    assert_match(/Thumbnails and previews deleted, made again when shown\s+0$/, output)
    assert_equal bytes, @storage.download(lost.key)
  end

  test "certtrack:restore_files stops when copies are off" do
    errors = run_task("certtrack:restore_files", dir: nil, aborts: true)

    assert_includes errors, "FILE_COPY_DIR is not set"
  end

  test "certtrack:file_copy_status prints counts, bytes, the trash and free space" do
    travel_to Time.zone.local(2026, 11, 4, 4, 15)
    certificate = certificates(:juan_osha30)
    certificate_blob(certificate)
    trashed = certificate_blob(certificate)
    run_copy
    certificate.files.find_by!(blob_id: trashed.id).purge
    run_copy
    certificate_blob(certificate)

    output = run_task("certtrack:file_copy_status")

    assert_includes output, "File copies in #{@store.root}"
    assert_match(/Last run\s+Nov 4, 2026 4:15 AM MST \(complete\)$/, output)
    assert_match(/Last complete copy\s+Nov 4, 2026 4:15 AM MST$/, output)
    assert_match(/Files to keep\s+2 \(\d+ Bytes\)$/, output)
    assert_match(/Copied\s+1 \(\d+ Bytes\)$/, output)
    assert_match(/Not copied yet\s+1$/, output)
    assert_match(/In the trash\s+1 \(\d+ Bytes\), oldest from 2026-11-04$/, output)
    assert_match(/Free space\s+60 GB of 100 GB \(copying stops under 10 GB\)$/, output)
  end

  test "certtrack:file_copy_status says when copies are off" do
    assert_includes run_task("certtrack:file_copy_status", dir: nil), "FILE_COPY_DIR is not set, so file copies are off."
  end

  private
    # Runs the task with FILE_COPY_DIR set to dir; returns stdout, or stderr when aborts: true.
    def run_task(name, dir: @copy_dir, aborts: false)
      Rake::Task[name].reenable
      output, errors = capture_io do
        with_env("FILE_COPY_DIR" => dir) do
          if aborts
            assert_raises(SystemExit) { Rake::Task[name].invoke }
          else
            Rake::Task[name].invoke
          end
        end
      end
      aborts ? errors : output
    end
end
