require_relative "backups_test_support"

# Shared helpers for the file copy tests. Required by them; not a test file itself.
#
# Both sides are Disk services in tmp dirs: the test storage service (tmp/storage) stands in
# for R2, and each test gets its own empty FILE_COPY_DIR.
module FileCopyTestSupport
  include BackupsTestSupport

  # 100 GB disk, so the reserve is 10 GB.
  ROOMY_DISK = Backups::FileCopyStore::DiskSpace.new(total_bytes: 100.gigabytes, free_bytes: 60.gigabytes)

  def self.included(base)
    base.setup do
      @copy_dir = Dir.mktmpdir("file_copies")
      @store = Backups::FileCopyStore.new(@copy_dir)
      @default_disk_space_reader = Backups::FileCopyStore.disk_space_reader
      use_disk_space ROOMY_DISK
    end

    base.teardown do
      Backups::FileCopyStore.disk_space_reader = @default_disk_space_reader
      FileUtils.chmod_R("u+rwx", @copy_dir) if File.directory?(@copy_dir)
      FileUtils.rm_rf(@copy_dir)
    end
  end

  def use_disk_space(space)
    Backups::FileCopyStore.disk_space_reader = ->(_root) { space }
  end

  def with_copy_dir(dir = @copy_dir, &block)
    with_env("FILE_COPY_DIR" => dir, &block)
  end

  def run_copy(store: @store)
    Backups::FileCopy.new(store:).call
  end

  def upload_blob(content = "%PDF-1.4 #{SecureRandom.hex(16)}", filename: "card.pdf", content_type: "application/pdf")
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(content), filename:, content_type:)
  end

  def certificate_blob(certificate = certificates(:juan_osha30), **options)
    upload_blob(**options).tap { |blob| certificate.files.attach(blob) }
  end

  def import_item_blob(item = import_items(:review_juan_first_aid))
    upload_blob.tap { |blob| item.file.attach(blob) }
  end

  def index_pdf_blob(project = projects(:tower_2417))
    upload_blob(filename: "index.pdf").tap do |blob|
      project.packet_builds.create!(built_at: Time.current, packet_filename: "2417-packet.zip", index_pdf: blob)
    end
  end

  # Blobs nothing should copy: a variant and a preview image of parent, a packet zip, an
  # import's raw upload and a blob attached to nothing.
  def blobs_not_worth_copying(parent)
    variant = ActiveStorage::VariantRecord.create!(blob: parent, variation_digest: SecureRandom.hex(8))
    [
      upload_blob(filename: "thumb.png", content_type: "image/png").tap { |blob| variant.image.attach(blob) },
      upload_blob(filename: "preview.png", content_type: "image/png").tap { |blob| parent.preview_image.attach(blob) },
      upload_blob(filename: "packet.zip", content_type: "application/zip").tap { |blob| projects(:tower_2417).packet.attach(blob) },
      upload_blob(filename: "drop.zip", content_type: "application/zip").tap { |blob| import_batches(:march_batch).uploads.attach(blob) },
      upload_blob
    ]
  end

  # Writes status.json as a run that finished at finished_at would have.
  def record_run(finished_at:, outcome:, last_success_at: (finished_at if outcome == "complete"), failed: 0,
    not_copied: failed, free_bytes: 60.gigabytes, reserve_bytes: 10.gigabytes)
    @store.write_status("finished_at" => finished_at.utc.iso8601, "outcome" => outcome,
      "last_success_at" => last_success_at&.utc&.iso8601, "failed" => failed, "not_copied" => not_copied,
      "free_bytes" => free_bytes, "total_bytes" => 100.gigabytes, "reserve_bytes" => reserve_bytes)
  end

  def copied_bytes(blob, store: @store)
    File.binread(store.path_for(blob.key))
  end

  # Counts the storage service's streaming and whole-file downloads during the block.
  def count_downloads
    counts = Hash.new(0)
    callback = ->(name, *) { counts[name.delete_prefix("service_").delete_suffix(".active_storage")] += 1 }
    ActiveSupport::Notifications.subscribed(callback, /\Aservice_(streaming_)?download\.active_storage\z/) { yield }
    counts
  end
end
