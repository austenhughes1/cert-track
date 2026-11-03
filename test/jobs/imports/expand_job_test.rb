require "test_helper"
require "support/import_samples"

class Imports::ExpandJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @user = users(:manager)
    @pdf = ImportSamples.pdf({})
  end

  test "a plain upload becomes one pending item that reuses the upload's blob" do
    batch = ImportSamples.batch(@user, "ortiz.pdf" => @pdf)

    perform(batch)

    batch.reload
    assert batch.processing?
    assert_equal 1, batch.files_count
    item = batch.import_items.sole
    assert item.pending?
    assert_equal [ "ortiz.pdf", Digest::SHA256.hexdigest(@pdf), nil ], [ item.original_filename, item.sha256, item.page_range ]
    assert_equal batch.uploads.sole.blob, item.file.blob
    assert_enqueued_with(job: Imports::ExtractTextJob, args: [ item ])
    assert_no_enqueued_emails
  end

  test "a mislabelled upload gets a blob with the real content type" do
    batch = ImportSamples.batch(@user, "scan.jpg" => @pdf)

    perform(batch)

    item = batch.import_items.sole
    assert_not_equal batch.uploads.sole.blob, item.file.blob
    assert_equal [ "application/pdf", "scan.jpg", @pdf ], [ item.file.content_type, item.file.filename.to_s, item.file.download ]
  end

  test "a zip becomes one item per file, named by its path, each with its own file" do
    png = ImportSamples.image({ holder: "Li Chen" }, format: :png)
    zip = ImportSamples.zip("cards/" => nil, "cards/ortiz.pdf" => @pdf, "cards/chen.png" => png,
      "__MACOSX/cards/._chen.png" => "junk", "notes.txt" => "renew in May", "../evil.pdf" => ImportSamples.pdf({ number: "EVIL" }))
    batch = ImportSamples.batch(@user, "crew.zip" => zip)

    perform(batch)

    items = batch.import_items.order(:id).to_a
    assert_equal [ "crew.zip/cards/ortiz.pdf", "crew.zip/cards/chen.png", "crew.zip/notes.txt", "crew.zip/../evil.pdf" ],
      items.map(&:original_filename)
    assert_equal %w[pending pending rejected rejected], items.map(&:status)
    assert_equal 4, batch.reload.files_count

    ortiz, chen, notes, evil = items
    assert_equal [ "ortiz.pdf", "application/pdf", @pdf ], [ ortiz.file.filename.to_s, ortiz.file.content_type, ortiz.file.download ]
    assert_equal [ "chen.png", "image/png" ], [ chen.file.filename.to_s, chen.file.content_type ]
    assert_match "Unsupported file type", notes.rejection_reason
    assert_match "zip-slip", evil.rejection_reason
    assert_nil evil.sha256
    assert_not evil.file.attached?

    assert_equal [ ortiz, chen ], enqueued_jobs.select { |job| job["job_class"] == "Imports::ExtractTextJob" }
      .map { |job| ActiveJob::Arguments.deserialize(job["arguments"]).first }
  end

  test "the same file twice in one batch: the second is a duplicate of the first" do
    batch = ImportSamples.batch(@user, "ortiz.pdf" => @pdf, "crew.zip" => ImportSamples.zip("again/ortiz copy.pdf" => @pdf))

    perform(batch)

    original, copy = batch.import_items.order(:id).to_a
    assert original.pending?
    assert copy.duplicate?
    assert_equal original, copy.duplicate_of
    assert_equal "crew.zip/again/ortiz copy.pdf", copy.original_filename
    assert_equal original.sha256, copy.sha256
    assert_not copy.file.attached?
    assert_enqueued_jobs 1, only: Imports::ExtractTextJob
  end

  test "a file seen in an earlier batch is a duplicate of the earlier item (the whole file, not a page)" do
    earlier = ImportSamples.batch(users(:admin), "two certs.pdf" => @pdf)
    perform(earlier)
    whole = earlier.import_items.sole
    whole.update!(status: :needs_review, page_range: "1")
    earlier.import_items.create!(status: :needs_review, sha256: whole.sha256, page_range: "2", source_item: whole)

    batch = ImportSamples.batch(@user, "renamed.pdf" => @pdf)
    perform(batch)

    copy = batch.import_items.sole
    assert copy.duplicate?
    assert_equal whole, copy.duplicate_of
  end

  test "a file whose earlier item failed is read again, not called a duplicate" do
    earlier = ImportSamples.batch(@user, "ortiz.pdf" => @pdf)
    perform(earlier)
    earlier.import_items.sole.update!(status: :failed, error_message: "OCR failed")

    batch = ImportSamples.batch(@user, "ortiz.pdf" => @pdf)
    perform(batch)

    assert batch.import_items.sole.pending?
  end

  test "every file is accounted for: an acceptance-style zip" do
    heic = ImportSamples.heic_supported? ? ImportSamples.image({ holder: "Maria Garcia" }, format: :heic) : file_fixture("certificate.heic").binread
    multi = ImportSamples.pdf({}, { holder: "Li Chen", name: "Flagger Certification" }, :outline)
    files = {
      "multi.pdf" => multi,
      "IMG_0042.HEIC" => heic,
      "photo.jpg" => ImportSamples.image({ holder: "Dave Miller" }, format: :jpeg),
      "outline.pdf" => ImportSamples.pdf(:outline),
      "copy of multi.pdf" => multi,
      "../evil.pdf" => @pdf,
      "readme.txt" => "hello",
      ".DS_Store" => "junk",
      "nested.zip" => ImportSamples.nested_zip(1, "deep/card.webp" => ImportSamples.image({ holder: "Sam Price" }, format: :webp)),
      "too_deep.zip" => ImportSamples.nested_zip(2, "card.pdf" => ImportSamples.pdf({ number: "DEEP" }))
    }
    batch = ImportSamples.batch(@user, "samples.zip" => ImportSamples.zip(files))

    perform(batch)

    items = batch.import_items.order(:id).to_a
    by_name = items.index_by { |item| item.original_filename.delete_prefix("samples.zip/") }
    assert_equal 9, items.size # 10 entries: .DS_Store skipped; each nested zip counts as what's inside it
    assert_equal batch.reload.files_count, items.size
    assert_equal %w[pending] * 5, by_name.values_at("multi.pdf", "IMG_0042.HEIC", "photo.jpg", "outline.pdf",
      "nested.zip/level1.zip/deep/card.webp").map(&:status)
    assert_equal "image/heic", by_name["IMG_0042.HEIC"].file.content_type
    assert_equal by_name["multi.pdf"], by_name["copy of multi.pdf"].duplicate_of
    assert_match "zip-slip", by_name["../evil.pdf"].rejection_reason
    assert_match "Unsupported", by_name["readme.txt"].rejection_reason
    assert_match "nested more than 2 levels", by_name["too_deep.zip/level1.zip/level2.zip"].rejection_reason
    assert_enqueued_jobs 5, only: Imports::ExtractTextJob
  end

  test "a zip nested three levels deep is rejected; two levels is read" do
    batch = ImportSamples.batch(@user,
      "two.zip" => ImportSamples.nested_zip(2, "card.pdf" => @pdf),
      "three.zip" => ImportSamples.nested_zip(3, "card.pdf" => ImportSamples.pdf({ number: "3" })))

    perform(batch)

    assert_equal [ [ "two.zip/level1.zip/level2.zip/card.pdf", "pending" ], [ "three.zip/level1.zip/level2.zip/level3.zip", "rejected" ] ],
      batch.import_items.order(:id).pluck(:original_filename, :status)
  end

  test "stops at the entry limit, accounts for the rest, and says so on the batch" do
    zip = ImportSamples.zip((1..4).to_h { |n| [ "card#{n}.pdf", ImportSamples.pdf({ number: "N-#{n}" }) ] })
    batch = ImportSamples.batch(@user, "crew.zip" => zip, "late.pdf" => ImportSamples.pdf({ number: "LATE" }))

    Imports::Config.with(max_entries: 2) { perform(batch) }

    assert_equal [ [ "crew.zip/card1.pdf", "pending" ], [ "crew.zip/card2.pdf", "pending" ],
                   [ "crew.zip/card3.pdf", "rejected" ], [ "late.pdf", "rejected" ] ],
      batch.import_items.order(:id).pluck(:original_filename, :status)
    batch.reload
    assert_equal 4, batch.files_count
    assert_match "Stopped at the 2-file limit for one batch: crew.zip/card3.pdf", batch.error_message
    assert_enqueued_jobs 2, only: Imports::ExtractTextJob
  end

  test "stops at the uncompressed byte limit (zip-bomb guard)" do
    bomb = ImportSamples.declare_size(ImportSamples.zip("bomb.pdf" => "%PDF-1.4\n" + "\0" * 300_000), "bomb.pdf", 10)
    batch = ImportSamples.batch(@user, "bomb.zip" => bomb)

    Imports::Config.with(max_uncompressed_bytes: 100_000) { perform(batch) }

    item = batch.import_items.sole
    assert item.rejected?
    assert_match "uncompressed limit", item.rejection_reason
    assert_match "zip-bomb guard", batch.reload.error_message
    assert batch.completed?
  end

  test "a batch over the size limit imports nothing" do
    batch = ImportSamples.batch(@user, "a.pdf" => @pdf, "b.pdf" => ImportSamples.pdf({ number: "B" }))

    Imports::Config.with(max_batch_bytes: 1_000) { perform(batch) }

    assert_equal %w[rejected rejected], batch.import_items.pluck(:status)
    assert_match "over the 1000 Bytes batch limit", batch.reload.error_message
    assert_no_enqueued_jobs only: Imports::ExtractTextJob
  end

  test "a corrupt zip is a rejected item and the batch finishes with a summary" do
    batch = ImportSamples.batch(@user, "crew.zip" => "PK\x03\x04 truncated download")

    assert_enqueued_emails 1 do
      perform(batch)
    end

    item = batch.import_items.sole
    assert item.rejected?
    assert_match "Couldn't open this zip", item.rejection_reason
    assert batch.reload.completed?
    assert batch.summary_sent_at.present?
  end

  test "an upload whose stored file is gone is a rejected item" do
    batch = ImportSamples.batch(@user, "ortiz.pdf" => @pdf, "chen.pdf" => ImportSamples.pdf({ holder: "Li Chen" }))
    gone = batch.uploads.find { |upload| upload.filename.to_s == "ortiz.pdf" }.blob
    gone.service.delete(gone.key)

    perform(batch)

    assert_equal [ [ "ortiz.pdf", "rejected" ], [ "chen.pdf", "pending" ] ],
      batch.import_items.order(:id).pluck(:original_filename, :status)
    assert_match "missing", batch.import_items.find_by(original_filename: "ortiz.pdf").rejection_reason
  end

  test "only junk: the batch fails with a reason" do
    batch = ImportSamples.batch(@user, "mac.zip" => ImportSamples.zip(".DS_Store" => "x", "__MACOSX/._a.pdf" => "y"))

    assert_enqueued_emails 1 do
      perform(batch)
    end

    batch.reload
    assert batch.failed?
    assert_equal 0, batch.files_count
    assert_match "Nothing to import", batch.error_message
    assert_match "2 system or hidden files", batch.error_message
  end

  test "runs once: a second run changes nothing" do
    batch = ImportSamples.batch(@user, "ortiz.pdf" => @pdf)
    perform(batch)

    assert_no_difference -> { ImportItem.count } do
      perform(batch)
    end
    assert_enqueued_jobs 1, only: Imports::ExtractTextJob
  end

  test "skips the batch while another worker is unpacking it" do
    batch = ImportSamples.batch(@user, "ortiz.pdf" => @pdf)
    other_worker = other_session
    key = "#{Imports::ExpandJob::LOCK_NAMESPACE}, #{batch.id}"
    assert_equal "t", other_worker.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0)

    perform(batch)
    assert batch.reload.receiving?
    assert_empty batch.import_items

    other_worker.exec("SELECT pg_advisory_unlock(#{key})")
    perform(batch)
    assert batch.reload.processing?
  ensure
    other_worker&.close
  end

  test "a run that died while unpacking is redone from scratch" do
    batch = ImportSamples.batch(@user, "ortiz.pdf" => @pdf)
    batch.processing!
    batch.import_items.create!(status: :pending, sha256: Digest::SHA256.hexdigest(@pdf), original_filename: "ortiz.pdf")

    perform(batch)

    item = batch.import_items.sole
    assert item.file.attached?
    assert_equal 1, batch.reload.files_count
    assert_enqueued_jobs 1, only: Imports::ExtractTextJob
  end

  test "an unexpected error is reported, recorded on the batch, and items made so far are still read" do
    batch = ImportSamples.batch(@user, "a.pdf" => @pdf, "b.pdf" => ImportSamples.pdf({ number: "B" }))

    assert_error_reported(RuntimeError) do
      ExplodingExpandJob.perform_now(batch)
    end

    batch.reload
    assert_match "Unpacking stopped unexpectedly (RuntimeError)", batch.error_message
    assert_equal [ "a.pdf" ], batch.import_items.pluck(:original_filename)
    assert_equal 2, batch.files_count # so a later run doesn't wipe and redo it
    assert_enqueued_jobs 1, only: Imports::ExtractTextJob
    assert batch.processing?
  end

  class ExplodingExpandJob < Imports::ExpandJob
    private
      def record(batch, entry, pending, **options)
        raise "storage fell over" if entry.name == "b.pdf"

        super
      end
  end

  private
    def perform(batch)
      Imports::ExpandJob.perform_now(batch)
    end

    # A second database session, like another Solid Queue worker's (the test's own
    # connection is pinned, so the pool can't hand out a different one).
    def other_session
      config = ImportBatch.connection_db_config.configuration_hash
      PG.connect({ dbname: config[:database], host: config[:host], port: config[:port], user: config[:username],
                   password: config[:password] }.compact)
    end
end
