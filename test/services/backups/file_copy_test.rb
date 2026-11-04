require "test_helper"
require_relative "file_copy_test_support"

class Backups::FileCopyTest < ActiveSupport::TestCase
  include FileCopyTestSupport

  test "copies certificate files, import item files and packet index PDFs, and nothing else" do
    certificate_file = certificate_blob
    kept = [ certificate_file, import_item_blob, index_pdf_blob ]
    skipped = blobs_not_worth_copying(certificate_file)

    result = run_copy

    assert_equal "complete", result.outcome
    assert_equal 3, result.kept
    assert_equal 3, result.copied
    assert_equal kept.sum(&:byte_size), result.copied_bytes
    assert_equal 0, result.not_copied
    kept.each { |blob| assert_equal blob.download, copied_bytes(blob) }
    skipped.each { |blob| assert_not File.exist?(@store.path_for(blob.key)), "#{blob.filename} should not be copied" }
  end

  test "streams each missing file once and downloads nothing on the next run" do
    blobs = Array.new(3) { certificate_blob }

    first = count_downloads { run_copy }
    second = nil
    again = count_downloads { second = run_copy }

    assert_equal({ "streaming_download" => 3 }, first)
    assert_equal({}, again)
    assert_equal 0, second.copied
    assert_equal 3, second.kept
    blobs.each { |blob| assert_equal blob.download, copied_bytes(blob) }
  end

  test "copies real photos and PDFs byte for byte, not only text" do
    blobs = { "certificate.jpg" => "image/jpeg", "certificate.pdf" => "application/pdf", "certificate.heic" => "image/heic" }
      .map { |name, content_type| upload_blob(file_fixture(name).binread, filename: name, content_type:) }
    certificates(:juan_osha30).files.attach(blobs)
    assert blobs.any? { |blob| !blob.download.dup.force_encoding(Encoding::UTF_8).valid_encoding? }, "the fixtures hold non-UTF-8 bytes"

    result = run_copy

    assert result.complete?, result.errors.inspect
    assert_equal 3, result.copied
    blobs.each { |blob| assert_equal blob.download, copied_bytes(blob) }
  end

  test "copies a new file again when its copy has the wrong size" do
    blob = certificate_blob
    run_copy
    File.write(@store.path_for(blob.key), "truncated")

    assert_equal 1, run_copy.copied
    assert_equal blob.download, copied_bytes(blob)
  end

  test "keeps nothing whose bytes don't match the blob's MD5, and reports it" do
    good = certificate_blob
    bad = certificate_blob
    ActiveStorage::Blob.service.upload(bad.key, StringIO.new("X" * bad.byte_size)) # same size, other bytes

    result = nil
    assert_error_reported(Backups::FileCopy::CopyError) { result = run_copy }

    assert_equal "incomplete", result.outcome
    assert_equal 1, result.copied
    assert_equal 1, result.failed
    assert_equal 1, result.not_copied
    assert_match(/blob #{bad.id} .*IntegrityError.*MD5/, result.errors.sole)
    assert File.exist?(@store.path_for(good.key))
    assert_not File.exist?(@store.path_for(bad.key))
    assert_empty Dir.children(File.join(@store.root, "incoming"))
  end

  test "carries on past a file missing from storage" do
    missing = certificate_blob
    present = certificate_blob
    ActiveStorage::Blob.service.delete(missing.key)

    result = run_copy

    assert_equal "incomplete", result.outcome
    assert_equal [ 1, 1 ], [ result.copied, result.failed ]
    assert_match(/blob #{missing.id} .*FileNotFoundError/, result.errors.sole)
    assert_equal present.download, copied_bytes(present)
  end

  test "gives up after 20 failures in a row, as when storage is unreachable" do
    certificate = certificates(:juan_osha30)
    blobs = Array.new(22) { certificate_blob(certificate) }
    blobs.each { |blob| ActiveStorage::Blob.service.delete(blob.key) }

    result = run_copy

    assert_equal 20, result.failed
    assert_equal 10, result.errors.size
    assert_equal 22, result.not_copied
  end

  test "stops copying before free space drops under the reserve, and reports it" do
    blobs = Array.new(3) { certificate_blob }
    reserve = 10.gigabytes # of a 100 GB disk
    use_disk_space Backups::FileCopyStore::DiskSpace.new(total_bytes: 100.gigabytes,
      free_bytes: reserve + blobs.first.byte_size + 1)

    result = nil
    assert_error_reported(Backups::FileCopy::LowSpaceError) { result = run_copy }

    assert_equal "low_space", result.outcome
    assert_equal 1, result.copied
    assert_equal 2, result.not_copied
    assert File.exist?(@store.path_for(blobs.first.key))
    status = @store.read_status
    assert_equal "low_space", status["outcome"]
    assert_equal 2, status["not_copied"]
    assert_equal reserve, status["reserve_bytes"]
  end

  test "copies nothing when the disk is already under the reserve" do
    certificate_blob
    use_disk_space Backups::FileCopyStore::DiskSpace.new(total_bytes: 100.gigabytes, free_bytes: 9.gigabytes)

    result = nil
    downloads = count_downloads do
      assert_error_reported(Backups::FileCopy::LowSpaceError) { result = run_copy }
    end

    assert_equal({}, downloads)
    assert_equal [ "low_space", 0, 1 ], [ result.outcome, result.copied, result.not_copied ]
  end

  test "moves copies of deleted files to a dated trash and deletes them 30 days later" do
    travel_to Time.zone.local(2026, 11, 4, 4, 15)
    certificate = certificates(:juan_osha30)
    blob = certificate_blob(certificate)
    run_copy

    certificate.files.find_by!(blob_id: blob.id).purge
    result = Backups::FileCopy.new(store: @store).call

    assert_equal 1, result.trashed
    assert_not File.exist?(@store.path_for(blob.key))
    assert File.exist?(@store.trash_path_for(blob.key, Date.new(2026, 11, 4)))

    travel 29.days
    assert_equal 0, run_copy.expired
    assert File.exist?(@store.trash_path_for(blob.key, Date.new(2026, 11, 4)))

    travel 1.day
    assert_equal 1, run_copy.expired
    assert_empty @store.trash_days
  end

  test "a copy whose file comes back with a database restore on its 30th day in the trash leaves the trash before it expires" do
    travel_to Time.zone.local(2026, 11, 4, 4, 15)
    certificate = certificates(:juan_osha30)
    blob = certificate_blob(certificate)
    content = blob.download
    run_copy
    row = blob.attributes.slice("key", "filename", "content_type", "metadata", "service_name", "byte_size", "checksum")
    certificate.files.find_by!(blob_id: blob.id).purge # the row and the stored file are both gone
    assert_equal 1, run_copy.trashed

    travel 30.days # the night that trash folder expires
    restored = ActiveStorage::Blob.create!(row) # the database restore brings the row back
    certificate.reload.files.attach(restored)
    result = run_copy

    assert_equal [ 1, 0, 0, 0 ], [ result.untrashed, result.expired, result.failed, result.copied ]
    assert result.complete?
    assert_equal content, copied_bytes(restored)
    assert_empty @store.trash_days
  end

  test "trashes the copy of a file nothing kept uses any more, and brings it back without a download when it returns" do
    certificate = certificates(:juan_osha30)
    blob = certificate_blob(certificate)
    run_copy

    certificate.files.find_by!(blob_id: blob.id).delete # the blob stays, attached to nothing
    assert_equal 1, run_copy.trashed

    certificate.reload.files.attach(blob) # e.g. its row came back with a database restore
    result = nil
    downloads = count_downloads { result = run_copy }

    assert_equal({}, downloads)
    assert_equal [ 1, 0 ], [ result.untrashed, result.copied ]
    assert_equal blob.download, copied_bytes(blob)
    assert_equal [ 0, 0 ], @store.trash_usage
  end

  test "clears downloads a crashed run left behind" do
    FileUtils.mkdir_p(File.join(@store.root, "incoming"))
    File.write(File.join(@store.root, "incoming", "half-a-file"), "partial")

    run_copy

    assert_not File.exist?(File.join(@store.root, "incoming", "half-a-file"))
  end

  test "records the last complete copy, and keeps it through runs that fall short" do
    travel_to Time.zone.local(2026, 11, 2, 4, 15)
    certificate_blob
    run_copy
    assert_equal "2026-11-02T11:15:00Z", @store.read_status["last_success_at"]

    travel 1.day
    ActiveStorage::Blob.service.delete(certificate_blob.key)
    run_copy

    status = @store.read_status
    assert_equal "incomplete", status["outcome"]
    assert_equal "2026-11-03T11:15:00Z", status["finished_at"]
    assert_equal "2026-11-02T11:15:00Z", status["last_success_at"]
    assert_equal 60.gigabytes, status["free_bytes"]
  end

  test "refuses to run without a usable folder" do
    store = Backups::FileCopyStore.new(File.join(@copy_dir, "missing"))

    assert_raises(Backups::FileCopyStore::DirectoryError) { run_copy(store:) }
  end
end
