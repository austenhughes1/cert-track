require "test_helper"

class ImportBatchTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper
  test "defaults to receiving with zero counts" do
    batch = ImportBatch.create!(uploaded_by: users(:manager))
    assert batch.receiving?
    assert_equal 0, batch.items_count
  end

  test "requires an uploader" do
    assert_not ImportBatch.new.valid?
  end

  test "status enum" do
    assert_equal %w[receiving processing needs_review completed failed], ImportBatch.statuses.keys
    assert_includes ImportBatch.needs_review, import_batches(:march_batch)
  end

  test "refresh_counts! recomputes counters" do
    batch = import_batches(:march_batch)
    batch.update_columns(items_count: 0, accepted_count: 0, review_count: 0)
    batch.import_items.create!(sha256: "f" * 64, status: :failed, error_message: "OCR failed")

    batch.refresh_counts!
    assert_equal [ 4, 1, 1, 1 ], [ batch.items_count, batch.accepted_count, batch.review_count, batch.error_count ]
    assert_equal 1, batch.duplicate_count
  end

  test "all_items_terminal?" do
    batch = import_batches(:march_batch)
    assert_not batch.all_items_terminal?
    import_items(:review_juan_first_aid).rejected!
    assert batch.all_items_terminal?
    assert_not ImportBatch.create!(uploaded_by: users(:admin)).all_items_terminal?
  end

  test "uploads attachment" do
    batch = ImportBatch.create!(uploaded_by: users(:manager))
    batch.uploads.attach(io: StringIO.new("PK"), filename: "certs.zip", content_type: "application/zip")
    assert_equal 1, batch.uploads.count
  end

  test "discard_uploads! deletes the uploads, keeping a file an item still uses" do
    batch = ImportBatch.create!(uploaded_by: users(:manager))
    batch.uploads.attach([ upload("crew.zip", "PK zip"), upload("ortiz.pdf", "%PDF-1.4 ortiz") ])
    zip, pdf = batch.uploads.blobs.order(:id).to_a
    item = batch.import_items.create!(status: :pending, sha256: "c" * 64, original_filename: "ortiz.pdf", file: pdf)

    assert_equal 2, perform_enqueued_jobs { batch.discard_uploads! }

    assert_not batch.uploads.attached?
    assert_not batch.reload.uploads.attached?
    assert_not ActiveStorage::Blob.exists?(zip.id)
    assert_not zip.service.exist?(zip.key)
    assert_equal "%PDF-1.4 ortiz", item.reload.file.download
    assert_equal 0, batch.discard_uploads!
  end

  test "purge_stale_uploads! deletes uploads still kept 30 days after the drop" do
    old = ImportBatch.create!(uploaded_by: users(:manager), status: :processing, created_at: 31.days.ago)
    old.uploads.attach(upload("crew.zip", "PK old"))
    recent = ImportBatch.create!(uploaded_by: users(:manager), created_at: 29.days.ago)
    recent.uploads.attach(upload("new.zip", "PK new"))

    assert_equal 1, perform_enqueued_jobs { ImportBatch.purge_stale_uploads! }

    assert_not old.reload.uploads.attached?
    assert_equal [ "new.zip" ], recent.reload.uploads.map { |file| file.filename.to_s }
    assert_equal 1, ActiveStorage::Blob.count
  end

  test "destroying a batch removes its items and keeps certificates" do
    batch = import_batches(:march_batch)
    batch.destroy!
    assert_equal 0, ImportItem.where(import_batch_id: batch.id).count
    assert_nil certificates(:li_flagger).reload.import_item_id
  end

  # --- counts and progress ---

  test "status_counts, duplicate_count and rejected_count count the items" do
    batch = import_batches(:march_batch)
    add_item(batch, :rejected, sha256: nil, rejection_reason: "Unsafe path in zip")

    assert_equal({ "pending" => 0, "extracting" => 0, "needs_review" => 1, "accepted" => 1, "rejected" => 1,
                   "duplicate" => 1, "failed" => 0 }, batch.status_counts)
    assert_equal 1, batch.duplicate_count
    assert_equal 1, batch.rejected_count
    assert_equal ImportItem.statuses.keys.index_with(0), ImportBatch.new.status_counts
  end

  test "progress for the UI" do
    batch = new_batch(:processing)
    add_item(batch, :pending)
    add_item(batch, :extracting, next_attempt_at: 3.hours.from_now)
    add_item(batch, :extracting, next_attempt_at: 1.minute.ago)
    add_item(batch, :needs_review)

    progress = batch.progress
    assert_equal({ pending: 1, extracting: 2, needs_review: 1, accepted: 0, rejected: 0, duplicate: 0, failed: 0,
                   total: 4, processed: 1, percent: 25, waiting_for_budget: 1 }, progress)
    assert_equal 0, batch.progress(now: 4.hours.from_now)[:waiting_for_budget]
    assert_equal({ total: 0, processed: 0, percent: 0, waiting_for_budget: 0 }, new_batch.progress.slice(:total, :processed, :percent, :waiting_for_budget))
  end

  test "preload_progress loads many batches in two queries" do
    busy = new_batch(:processing)
    add_item(busy, :pending, next_attempt_at: 1.hour.from_now)
    add_item(busy, :accepted)
    batches = [ import_batches(:march_batch), busy, new_batch ]

    assert_queries_count(2) { ImportBatch.preload_progress(batches) }
    assert_no_queries do
      assert_equal [ 3, 2, 0 ], batches.map { |batch| batch.progress[:total] }
      assert_equal 1, batches.second.progress[:waiting_for_budget]
      assert_equal 1, batches.first.duplicate_count
    end

    add_item(busy, :failed)
    assert_equal 2, busy.progress[:total] # preloaded until reload
    assert_equal 3, busy.reload.progress[:total]
  end

  test "in_progress and finished scopes" do
    receiving = new_batch
    assert_includes ImportBatch.in_progress, receiving
    assert_includes ImportBatch.finished, import_batches(:march_batch)
    assert_not_includes ImportBatch.finished, receiving
    assert import_batches(:march_batch).finished?
    assert_not receiving.finished?
  end

  # --- check_completion! ---

  test "check_completion! leaves a batch that hasn't been unpacked alone" do
    batch = new_batch(:receiving)

    assert_no_enqueued_emails { batch.check_completion! }
    assert batch.reload.receiving?
  end

  test "check_completion! keeps a batch processing while any item is still being read" do
    batch = new_batch(:processing)
    add_item(batch, :accepted)
    add_item(batch, :extracting)

    assert_no_enqueued_emails { batch.check_completion! }
    assert batch.reload.processing?
    assert_equal [ 2, 1 ], [ batch.items_count, batch.accepted_count ]
    assert_nil batch.summary_sent_at
  end

  test "check_completion! sets needs_review, then completed once the last review is done, emailing once" do
    batch = new_batch(:processing)
    add_item(batch, :accepted)
    review = add_item(batch, :needs_review)
    add_item(batch, :duplicate)

    assert_enqueued_email_with ImportMailer, :summary, params: { batch: batch } do
      batch.check_completion!
    end
    assert batch.reload.needs_review?
    assert batch.summary_sent_at.present?
    assert_equal [ 3, 1, 1, 0 ], [ batch.items_count, batch.accepted_count, batch.review_count, batch.error_count ]

    review.update!(status: :accepted)
    assert_no_enqueued_emails { batch.check_completion! }
    assert batch.reload.completed?
    assert_equal 0, batch.review_count
  end

  test "check_completion! fails a batch when every item failed, or there are none" do
    failed = new_batch(:processing)
    2.times { add_item(failed, :failed, error_message: "OCR failed") }
    assert_enqueued_emails(1) { failed.check_completion! }
    assert failed.reload.failed?
    assert_equal 2, failed.error_count

    empty = new_batch(:processing)
    assert_enqueued_emails(1) { empty.check_completion! }
    assert empty.reload.failed?
  end

  test "check_completion! completes a batch of accepted, rejected, duplicate and some failed items" do
    batch = new_batch(:processing)
    %i[accepted rejected duplicate failed].each { |status| add_item(batch, status) }

    batch.check_completion!
    assert batch.reload.completed?
  end

  test "check_completion! goes back to processing when an item is read again" do
    batch = new_batch(:processing)
    item = add_item(batch, :failed)
    batch.check_completion!
    assert batch.reload.failed?

    item.update!(status: :pending)
    assert_no_enqueued_emails { batch.check_completion! }
    assert batch.reload.processing?

    item.update!(status: :accepted)
    assert_no_enqueued_emails { batch.check_completion! }
    assert batch.reload.completed?
  end

  test "the summary goes out exactly once when callers race" do
    batch = new_batch(:processing)
    add_item(batch, :accepted)
    stale_copies = Array.new(4) { ImportBatch.find(batch.id) }

    assert_enqueued_emails(1) do
      stale_copies.map { |copy| Thread.new { copy.check_completion! } }.each(&:join)
      stale_copies.each(&:check_completion!)
    end
    assert ImportBatch.find(batch.id).completed?
  end

  test "a batch that already sent its summary never sends another" do
    batch = new_batch(:needs_review)
    batch.update_columns(summary_sent_at: 1.day.ago)
    add_item(batch, :accepted)

    assert_no_enqueued_emails { batch.check_completion! }
    assert batch.reload.completed?
  end

  private
    def new_batch(status = :receiving)
      ImportBatch.create!(uploaded_by: users(:manager), status: status)
    end

    def add_item(batch, status, **attributes)
      batch.import_items.create!({ status: status, sha256: SecureRandom.hex(32) }.merge(attributes))
    end

    def upload(filename, bytes)
      { io: StringIO.new(bytes), filename: filename, content_type: filename.end_with?(".zip") ? "application/zip" : "application/pdf" }
    end
end
