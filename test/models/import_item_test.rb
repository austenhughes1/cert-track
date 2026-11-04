require "test_helper"

class ImportItemTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def build(**attrs)
    ImportItem.new({ import_batch: import_batches(:march_batch), sha256: "a" * 64 }.merge(attrs))
  end

  def with_file(item)
    item.file.attach(io: StringIO.new("%PDF-1.4 stale"), filename: "card.pdf", content_type: "application/pdf")
    item.tap(&:save!)
  end

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ActiveRecord::Base.uncached(&block) }
    count
  end

  test "statuses and default" do
    assert_equal %w[pending extracting needs_review accepted rejected duplicate failed], ImportItem.statuses.keys
    assert build.pending?
  end

  test "validates sha256, page_range and confidence" do
    assert_not build(sha256: nil).valid?
    assert_not build(sha256: "xyz").valid?
    assert build(sha256: " #{"AB" * 32} ").tap(&:validate).sha256 == "ab" * 32
    assert_not build(page_range: "1-a").valid?
    assert build(page_range: "3").valid?
    assert build(page_range: " ").tap(&:validate).page_range.nil?
    assert_not build(confidence: 1.5).valid?
    assert build(confidence: 0.85).valid?
  end

  test "original_for finds the first non-duplicate item for a file and page range" do
    sha = import_items(:accepted_li_flagger).sha256
    assert_equal import_items(:accepted_li_flagger), ImportItem.original_for(sha, "1")
    assert_equal import_items(:review_juan_first_aid), ImportItem.original_for(sha.upcase, "2")
    assert_nil ImportItem.original_for(sha, "3")
    assert_nil ImportItem.original_for("b" * 64, nil)
  end

  test "original_for matches nil page ranges and skips failed items" do
    failed = build(sha256: "c" * 64, status: :failed).tap(&:save!)
    assert_nil ImportItem.original_for("c" * 64, nil)
    ok = build(sha256: "c" * 64).tap(&:save!)
    assert_equal ok, ImportItem.original_for("c" * 64, "")
    assert failed.persisted?
  end

  test "duplicates are stored and linked" do
    original = import_items(:accepted_li_flagger)
    copy = build(sha256: original.sha256, page_range: "1")
    copy.save!
    copy.mark_duplicate_of!(original)

    assert copy.reload.duplicate?
    assert_equal original, copy.duplicate_of
    assert_includes original.duplicates, copy
  end

  test "terminal and unfinished scopes" do
    assert_equal %w[accepted_li_flagger duplicate_li_flagger].map { import_items(_1) }.sort_by(&:id), ImportItem.terminal.order(:id).to_a
    assert_equal [ import_items(:review_juan_first_aid) ], ImportItem.unfinished.to_a
    assert_equal [ import_items(:review_juan_first_aid) ], ImportItem.review_queue.to_a
    assert import_items(:accepted_li_flagger).terminal?
  end

  test "pages" do
    assert_equal [ 1, 2, 3 ], build(page_range: "1-3").pages
    assert_equal [ 2 ], build(page_range: "2").pages
    assert_equal [], build.pages
  end

  test "proposed_certificate_number is encrypted" do
    assert_equal "FL-55501", import_items(:accepted_li_flagger).proposed_certificate_number
    assert_equal import_items(:accepted_li_flagger), ImportItem.find_by(proposed_certificate_number: "FL-55501")
  end

  test "associations" do
    item = import_items(:accepted_li_flagger)
    assert_equal certificates(:li_flagger), item.certificate
    assert_equal [ certificates(:li_flagger) ], item.created_certificates.to_a
    assert_equal crew_members(:li_chen), item.matched_crew_member
    assert_equal certificate_types(:flagger), item.matched_certificate_type
    assert_equal users(:manager), item.reviewed_by
    assert_equal({ "pages" => [ 1 ], "holder_name" => "LI CHEN", "certificate_type_code" => "FLAGGER", "confidence" => 0.93 }, item.extraction)
  end

  test "has an attached file" do
    item = build
    item.file.attach(io: StringIO.new("%PDF"), filename: "page1.pdf", content_type: "application/pdf")
    item.save!
    assert item.file.attached?
  end

  test "purge_stale_extractions! clears old text from finished items only" do
    accepted = import_items(:accepted_li_flagger)
    review = import_items(:review_juan_first_aid)
    accepted.update_columns(reviewed_at: 31.days.ago)
    review.update_columns(updated_at: 40.days.ago)

    assert_equal [ accepted ], ImportItem.purgeable.to_a
    assert_equal 1, ImportItem.purge_stale_extractions!
    assert_nil accepted.reload.extracted_text
    assert_nil accepted.extraction
    assert_not_nil review.reload.extracted_text
    assert_empty ImportItem.purgeable
  end

  test "failed items and split-off duplicates are purged too, 30 days after their last change" do
    text = "=== page 1 ===\nCDL CLASS A\nLICENSE NO D1234567\nDOB 1980-01-01"
    failed = build(sha256: "e" * 64, status: :failed, extracted_text: text, error_message: "AI extraction failed").tap(&:save!)
    split_duplicate = build(sha256: "e" * 64, page_range: "2", status: :duplicate, extracted_text: text,
      extraction: { "certificates" => [ { "holder_name" => "Li Chen" } ] }, duplicate_of: import_items(:accepted_li_flagger)).tap(&:save!)
    recent_failure = build(sha256: "f" * 64, status: :failed, extracted_text: text).tap(&:save!)
    rejected = build(sha256: "a" * 64, status: :rejected, extracted_text: text, reviewed_at: 31.days.ago).tap(&:save!)
    [ failed, split_duplicate ].each { |item| item.update_columns(updated_at: 31.days.ago) }
    rejected.update_columns(updated_at: 1.day.ago) # the review date counts, not a later change

    assert_equal [ failed, split_duplicate, rejected ].map(&:id).sort, ImportItem.purgeable.pluck(:id).sort
    assert_equal 3, ImportItem.purge_stale_extractions!
    [ failed, split_duplicate, rejected ].each do |item|
      assert_nil item.reload.extracted_text, item.status
      assert_nil item.extraction, item.status
    end
    assert_equal text, recent_failure.reload.extracted_text
    assert failed.failed? && split_duplicate.duplicate?, "only the text goes; the items stay"
  end

  test "purge_stale_files! deletes the files of items that failed more than 30 days ago, and nothing else" do
    failed = with_file(build(sha256: "e" * 64, status: :failed, error_message: "OCR failed"))
    recent_failure = with_file(build(sha256: "f" * 64, status: :failed))
    rejected = with_file(build(sha256: "a" * 64, status: :rejected, reviewed_at: 40.days.ago))
    review = with_file(build(sha256: "b" * 64, status: :needs_review))
    [ failed, rejected, review ].each { |item| item.update_columns(updated_at: 40.days.ago) }
    failed_blob = failed.file.blob

    assert_equal [ failed ], ImportItem.file_purgeable.to_a
    assert_no_changes -> { failed.reload.updated_at } do
      assert_equal 1, perform_enqueued_jobs { ImportItem.purge_stale_files! }
    end

    assert_not failed.reload.file.attached?
    assert failed.failed?, "only the file goes; the item stays"
    assert_not ActiveStorage::Blob.exists?(failed_blob.id)
    assert_not failed_blob.service.exist?(failed_blob.key)
    [ recent_failure, rejected, review ].each { |item| assert item.reload.file.attached?, item.status }
    assert_equal 0, ImportItem.purge_stale_files!
  end

  test "purge_stale_files! keeps a stored file a certificate still holds" do
    failed = with_file(build(sha256: "e" * 64, status: :failed))
    certificate = certificates(:li_flagger)
    certificate.files.attach(failed.file.blob)
    failed.update_columns(updated_at: 31.days.ago)

    perform_enqueued_jobs { ImportItem.purge_stale_files! }

    assert_not failed.reload.file.attached?
    assert_equal "%PDF-1.4 stale", certificate.reload.files.sole.download
  end

  test "a rejected item may have no digest; other items need one" do
    assert build(sha256: nil, status: :rejected, rejection_reason: "Unsafe path in zip").valid?
    assert_not build(sha256: nil, status: :pending).valid?
    assert_not build(sha256: "nope", status: :rejected).valid?
  end

  test "review_queue puts skipped items last, earliest skip first" do
    review = import_items(:review_juan_first_aid)
    skipped_early = build(status: :needs_review, skipped_at: 2.hours.ago).tap(&:save!)
    skipped_late = build(status: :needs_review, skipped_at: 1.hour.ago).tap(&:save!)
    fresh = build(status: :needs_review).tap(&:save!)

    assert_equal [ review, fresh, skipped_early, skipped_late ], ImportItem.review_queue.to_a

    review.update!(skipped_at: Time.current)
    assert_equal [ fresh, skipped_early, skipped_late, review ], ImportItem.review_queue.to_a
  end

  test "in_pipeline and waiting_for_budget" do
    waiting = build(status: :extracting, next_attempt_at: 2.hours.from_now).tap(&:save!)
    due = build(status: :extracting, next_attempt_at: 1.minute.ago).tap(&:save!)
    pending = build(status: :pending).tap(&:save!)
    build(status: :needs_review, next_attempt_at: 2.hours.from_now).save!

    assert_equal [ waiting, due, pending ], ImportItem.in_pipeline.order(:id).to_a
    assert_equal [ waiting ], ImportItem.waiting_for_budget.to_a
    assert_empty ImportItem.waiting_for_budget(3.hours.from_now)
    assert waiting.waiting_for_budget?
    assert_not waiting.waiting_for_budget?(3.hours.from_now)
    assert_not due.waiting_for_budget?
    assert pending.in_pipeline?
    assert_not import_items(:accepted_li_flagger).in_pipeline?
  end

  test "original_file_for finds the whole-file item for any page range" do
    sha = "d" * 64
    assert_nil ImportItem.original_file_for(sha)

    whole = build(sha256: sha, status: :needs_review, page_range: "1").tap(&:save!)
    build(sha256: sha, status: :needs_review, page_range: "2", source_item: whole).save!
    build(sha256: sha, status: :duplicate, duplicate_of: whole).save!
    assert_equal whole, ImportItem.original_file_for(sha.upcase)

    # the fixture file: its first item stands for it
    assert_equal import_items(:accepted_li_flagger), ImportItem.original_file_for(import_items(:accepted_li_flagger).sha256)

    whole.update!(status: :failed)
    assert_equal "2", ImportItem.original_file_for(sha).page_range
  end

  test "original_files_for finds original_file_for's item for many files in one query" do
    sha = "d" * 64
    whole = build(sha256: sha, status: :rejected, page_range: "1").tap(&:save!)
    build(sha256: sha, status: :needs_review, page_range: "2", source_item: whole).save!
    other = "e" * 64
    build(sha256: other, status: :failed).save!
    later = build(sha256: other, status: :needs_review).tap(&:save!)
    fixture = import_items(:accepted_li_flagger).sha256
    digests = [ sha.upcase, other, fixture, "f" * 64 ]

    originals = nil
    queries = count_queries { originals = ImportItem.original_files_for(digests) }

    assert_equal 1, queries
    assert_equal({ sha => whole, other => later, fixture => import_items(:accepted_li_flagger) }, originals)
    assert_equal digests.map { |digest| ImportItem.original_file_for(digest) }, digests.map { |digest| originals[digest.downcase] }
    assert_equal({}, ImportItem.original_files_for([]))
  end

  test "filename is the last part of original_filename" do
    assert_equal "ortiz.jpg", build(original_filename: "crew.zip/cards/ortiz.jpg").filename
    assert_equal "scan_0001.pdf", import_items(:accepted_li_flagger).filename
    assert_nil build(original_filename: nil).filename
  end

  test "destroying an original nullifies its duplicates" do
    original = import_items(:accepted_li_flagger)
    original.destroy!
    assert_nil import_items(:duplicate_li_flagger).reload.duplicate_of_id
    assert_nil certificates(:li_flagger).reload.import_item_id
  end
end
