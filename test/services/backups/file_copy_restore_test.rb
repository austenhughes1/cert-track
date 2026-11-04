require "test_helper"
require_relative "file_copy_test_support"

class Backups::FileCopyRestoreTest < ActiveSupport::TestCase
  include FileCopyTestSupport

  setup do
    @storage = ActiveStorage::Blob.service
  end

  test "a dry run counts the files it would put back and uploads nothing" do
    lost = certificate_blob
    safe = certificate_blob
    run_copy
    @storage.delete(lost.key)

    result = Backups::FileCopyRestore.new(store: @store).call

    assert_not result.confirm
    assert_equal [ 2, 0, 1, 1, 0 ], [ result.blobs, result.without_copy, result.in_storage, result.missing, result.restored ]
    assert_not @storage.exist?(lost.key)
    assert @storage.exist?(safe.key)
  end

  test "CONFIRM puts back files missing from storage, from live copies and from the trash" do
    certificate = certificates(:juan_osha30)
    live = certificate_blob(certificate)
    deleted = certificate_blob(certificate)
    contents = { live.key => live.download, deleted.key => deleted.download }
    run_copy
    # The certificate's file was deleted (its copy goes to the trash), then a database restore
    # brought its rows back but not the object in storage.
    attachment = certificate.files.find_by!(blob_id: deleted.id)
    rows = [ attachment.attributes, deleted.attributes ]
    attachment.purge
    run_copy
    ActiveStorage::Blob.insert!(rows.last)
    ActiveStorage::Attachment.insert!(rows.first)
    @storage.delete(live.key)

    result = Backups::FileCopyRestore.new(store: @store, confirm: true).call

    assert_equal [ 2, 2, 1, 0 ], [ result.missing, result.restored, result.from_trash, result.failed ]
    contents.each { |key, bytes| assert_equal bytes, @storage.download(key) }
  end

  test "a restored file's thumbnails and previews are deleted, so they are made again from it" do
    lost = certificate_blob(content_type: "image/jpeg", filename: "card.jpg")
    safe = certificate_blob
    lost_thumb, lost_preview = blobs_not_worth_copying(lost).first(2)
    safe_thumb, safe_preview = blobs_not_worth_copying(safe).first(2)
    run_copy
    # The bucket lost the photo and its thumbnail and preview; nothing copies those two.
    [ lost, lost_thumb, lost_preview ].each { |blob| @storage.delete(blob.key) }

    dry_run = Backups::FileCopyRestore.new(store: @store).call
    assert_equal 0, dry_run.representations
    assert ActiveStorage::VariantRecord.exists?(blob_id: lost.id), "a dry run changes nothing"

    result = Backups::FileCopyRestore.new(store: @store, confirm: true).call

    assert_equal [ 1, 2, 0 ], [ result.restored, result.representations, result.failed ]
    assert @storage.exist?(lost.key)
    assert_not ActiveStorage::VariantRecord.exists?(blob_id: lost.id)
    assert_not ActiveStorage::Blob.exists?(lost_thumb.id)
    assert_not ActiveStorage::Blob.exists?(lost_preview.id)
    assert_not lost.reload.preview_image.attached?
    assert ActiveStorage::VariantRecord.exists?(blob_id: safe.id), "files still in storage keep theirs"
    assert ActiveStorage::Blob.exists?(safe_thumb.id)
    assert safe.reload.preview_image.attached?
    assert_equal safe_preview, safe.preview_image.blob
  end

  test "leaves files still in storage alone" do
    blob = certificate_blob
    run_copy
    uploads = []
    callback = ->(*, payload) { uploads << payload[:key] }

    result = ActiveSupport::Notifications.subscribed(callback, "service_upload.active_storage") do
      Backups::FileCopyRestore.new(store: @store, confirm: true).call
    end

    assert_empty uploads
    assert_equal [ 1, 0 ], [ result.in_storage, result.restored ]
    assert_equal blob.checksum, ActiveStorage::Blob.find(blob.id).checksum
  end

  test "never uploads a copy that fails the blob's checksum" do
    blob = certificate_blob
    run_copy
    @storage.delete(blob.key)
    File.write(@store.path_for(blob.key), "Y" * blob.byte_size)

    result = Backups::FileCopyRestore.new(store: @store, confirm: true).call

    assert_equal [ 1, 0, 0 ], [ result.bad_copies, result.missing, result.restored ]
    assert_not @storage.exist?(blob.key)
  end

  test "counts blobs without a copy without asking storage about them" do
    certificate_blob
    checks = []
    callback = ->(*, payload) { checks << payload[:key] }

    result = ActiveSupport::Notifications.subscribed(callback, "service_exist.active_storage") do
      Backups::FileCopyRestore.new(store: @store).call
    end

    assert_equal [ 1, 1 ], [ result.blobs, result.without_copy ]
    assert_empty checks
  end

  test "refuses a missing folder" do
    store = Backups::FileCopyStore.new(File.join(@copy_dir, "missing"))

    assert_raises(Backups::FileCopyStore::DirectoryError) { Backups::FileCopyRestore.new(store:).call }
  end
end
