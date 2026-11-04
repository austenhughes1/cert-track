require "test_helper"
require "zip"
require "support/import_samples"
require_relative "../services/backups/file_copy_test_support"

# One certificate's files from the drop zone to deletion, through every storage rule the owner
# set on 2026-11-04 (docs/PLAN.md, "Storage and email changes (Nov 4, 2026)"):
#
#   a zip on Imports (an iPhone HEIC photo and a scanned PDF of the same card) -> the real
#   pipeline (fake AI) -> the reviewer merges both into one certificate
#   -> Certificates::ShrinkFilesJob -> the nightly file copy (Backups::FileCopyJob)
#   -> a packet, then the 7-day zip purge (Maintenance::PurgeOldPacketsJob)
#   -> the certificate is deleted -> its copies wait 30 days in the file copy's trash
#
# Only the AI model is faked (AI_PROVIDER is always fake in tests). The test Disk service stands
# in for R2, and the file copy goes to a temp folder (FileCopyTestSupport).
class CertificateStorageLifecycleTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include FileCopyTestSupport

  CARD = { holder: "Juan A. Ortiz", number: "30-2468101", completed: "2026-06-01" }.freeze
  # A committed synthetic photo of CARD, so this runs where libheif can only decode (CI): dark
  # text on a white sheet in a 4032 x 3024 frame, like a 12 MP iPhone photo. Made with
  # ImportSamples.certificate_text(**CARD) rendered by Vips::Image.text (dpi 300, "sans 12",
  # width 2100), centred, then heifsave_buffer(compression: :hevc, Q: 80).
  IPHONE_HEIC = File.expand_path("../fixtures/files/imports/synthetic_iphone_osha30.heic", __dir__)
  ZIP_NAME = "crew.zip".freeze

  setup do
    skip "libvips #{Vips.version_string} has no HEIF loader" if Vips.type_find("VipsOperation", "heifload").zero?
    Ai::FakeProvider.reset!
    @juan = crew_members(:juan_ortiz)
    @tower = projects(:tower_2417)
    @storage = ActiveStorage::Blob.service
  end

  teardown do
    Ai::FakeProvider.reset!
  end

  test "a dropped photo and scan become one shrunk certificate, copied nightly, and deleted for good with it" do
    start = Time.current

    # --- Drop the zip; the pipeline unpacks and reads it -----------------------------------
    sign_in_as users(:manager)
    zip = ImportSamples.zip("crew/IMG_0042.HEIC" => File.binread(IPHONE_HEIC), "crew/osha30_scan.pdf" => ImportSamples.scanned_pdf(CARD))
    upload = ImportSamples.blob(zip, filename: ZIP_NAME)
    post imports_path, params: { import: { uploads: [ "", upload.signed_id ] } }
    batch = ImportBatch.order(:id).last
    run_jobs

    batch.reload
    assert batch.needs_review?, batch.status_counts.inspect
    assert_not batch.uploads.attached?, "the zip is deleted once unpacked"
    assert_gone upload, "the zip"

    photo = batch.import_items.find_by!(original_filename: "#{ZIP_NAME}/crew/IMG_0042.HEIC")
    scan = batch.import_items.find_by!(original_filename: "#{ZIP_NAME}/crew/osha30_scan.pdf")
    heic = photo.file.blob
    original_scan = scan.file.blob
    assert_equal [ "image/heic", "application/pdf" ], [ heic.content_type, original_scan.content_type ]
    [ photo, scan ].each do |item|
      assert item.needs_review?, "#{item.original_filename}: #{item.error_message}"
      assert_equal [ @juan, certificate_types(:osha30), CARD[:number] ],
        [ item.matched_crew_member, item.matched_certificate_type, item.proposed_certificate_number ], item.original_filename
    end

    # --- Review: the HEIC is previewed as a JPEG, then both files merge into one certificate ---
    get import_review_path(photo)
    assert_response :success
    assert_select "input[name='other_ids[]'][value=?]", scan.id.to_s
    get css_select("#review_preview_image").first["src"]
    assert_response :redirect
    preview = ActiveStorage::VariantRecord.find_by!(blob_id: heic.id).image.blob
    assert_equal "image/jpeg", preview.content_type

    post merge_import_review_path(photo), params: { other_ids: [ scan.id ], review: {
      crew_member_id: @juan.id, certificate_type_id: certificate_types(:osha30).id, completed_on: CARD[:completed],
      expires_on: "", certificate_number: CARD[:number], issued_by: photo.issuer_raw
    } }
    assert_response :see_other
    certificate = photo.reload.certificate
    assert certificate, flash[:alert]
    assert_equal certificate, scan.reload.certificate
    assert batch.reload.completed?
    run_jobs

    # --- Stored once, shrunk ----------------------------------------------------------------
    jpeg, pdf = certificate.reload.files.sort_by { |file| file.filename.to_s }
    assert_equal [ [ "IMG_0042.jpg", "image/jpeg" ], [ "osha30_scan.pdf", "application/pdf" ] ],
      [ jpeg, pdf ].map { |file| [ file.filename.to_s, file.content_type ] }
    assert jpeg.blob.metadata["shrunk"]
    assert_equal [ 2400, 1800 ], dimensions(jpeg.blob), "the long side is 2400 px"
    assert pdf.blob.metadata["shrunk"], "a scanned page is stored at 200 ppi"
    assert_operator pdf.blob.byte_size, :<, original_scan.byte_size * 0.8
    assert_equal 1, CombinePDF.parse(pdf.download).pages.size
    assert_gone heic, "the HEIC original"
    assert_gone original_scan, "the full-size scan"
    assert_gone preview, "the review preview of the HEIC"
    assert_empty ActiveStorage::Attachment.where(record_type: ImportItem.name, record_id: batch.import_items.select(:id)),
      "the import items hold no files of their own"
    assert_equal certificate.files.blobs.ids.sort, ActiveStorage::Blob.ids.sort, "every stored file is the certificate's"

    # --- The nightly file copy copies exactly the certificate's files -------------------------
    copy = run_file_copy
    assert copy.complete?, copy.inspect
    assert_equal 2, copy.copied
    assert_equal certificate.files.blobs.map(&:key).sort, @store.keys.sort
    certificate.files.each { |file| assert_equal file.download, copied_bytes(file.blob) }

    # --- A packet; the morning after its last day its zip is purged and the index PDF stays --
    post project_packet_path(@tower)
    run_jobs
    @tower.reload
    assert @tower.packet.attached?
    zip_blob = @tower.packet.blob
    names = Zip::File.open_buffer(StringIO.new(zip_blob.download)).entries.map(&:name)
    assert_equal [ ".jpg", ".pdf" ], names.grep(/Ortiz_Juan - OSHA30/).map { |name| File.extname(name) }.sort
    build = @tower.packet_builds.sole
    assert_equal users(:manager), build.built_by
    index_bytes = build.index_pdf.download
    assert_equal index_bytes, Zip::File.open_buffer(StringIO.new(zip_blob.download)).read("index.pdf").b

    kept_until = @tower.packet_kept_until
    assert_equal @tower.packet_built_at.to_date + 7, kept_until
    travel_to kept_until.in_time_zone.change(hour: 3, minute: 50) # the nightly purge on its last day
    assert_equal 0, Maintenance::PurgeOldPacketsJob.perform_now

    purged_at = (kept_until + 1).in_time_zone.change(hour: 3, minute: 50)
    travel_to purged_at
    Maintenance::PurgeOldPacketsJob.perform_now
    run_jobs
    assert_not @tower.reload.packet.attached?
    assert_gone zip_blob, "the packet zip"
    assert_not_nil @tower.packet_built_at
    assert_equal index_bytes, build.reload.index_pdf.download, "the index PDF is the lasting record"
    get project_packet_path(@tower)
    assert_select "#packet_status[data-state=expired]"

    copy = run_file_copy
    assert_equal 1, copy.copied, "the index PDF is copied too; packet zips never are"
    assert_equal [ *certificate.files.blobs.map(&:key), build.index_pdf.key ].sort, @store.keys.sort

    # --- Deleting the certificate deletes its stored files; the copies wait 30 days ------------
    files = certificate.files.blobs.to_a
    sign_in_as users(:admin)
    delete crew_member_certificate_path(@juan, certificate)
    assert_response :see_other
    run_jobs
    files.each { |blob| assert_gone blob, blob.filename.to_s }
    assert_nil photo.reload.certificate

    deleted_on = Date.current
    copy = run_file_copy
    assert_equal 2, copy.trashed
    assert_equal [ build.index_pdf.key ], @store.keys
    files.each { |blob| assert File.file?(@store.trash_path_for(blob.key, deleted_on)), "#{blob.filename} is in the trash" }

    travel_to purged_at + 29.days
    assert_equal 0, run_file_copy.expired
    files.each { |blob| assert File.file?(@store.trash_path_for(blob.key, deleted_on)), "#{blob.filename} is kept 30 days" }

    travel_to purged_at + 30.days
    assert_equal 2, run_file_copy.expired
    files.each { |blob| assert_not File.exist?(@store.trash_path_for(blob.key, deleted_on)), "#{blob.filename} is deleted after 30 days" }
    assert_equal [ build.index_pdf.key ], @store.keys
    assert_equal index_bytes, build.reload.index_pdf.download
  end

  private
    # Performs everything due now, and every job those enqueue that is also due now, the way
    # Solid Queue would (no signed-in user).
    def run_jobs
      Current.reset
      perform_enqueued_jobs(at: Time.current) { perform_enqueued_jobs(at: Time.current) }
    end

    def run_file_copy
      with_copy_dir { Backups::FileCopyJob.perform_now }
    end

    # The blob row and its object in storage are both gone.
    def assert_gone(blob, label)
      assert_not ActiveStorage::Blob.exists?(blob.id), "#{label}: the blob row is deleted"
      assert_not @storage.exist?(blob.key), "#{label}: the stored file is deleted"
    end

    def dimensions(blob)
      blob.open { |file| Vips::Image.new_from_file(file.path).then { |image| [ image.width, image.height ] } }
    end
end
