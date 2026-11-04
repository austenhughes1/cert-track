require "test_helper"
require_relative "match_test_support"

class Imports::RereadTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  COMPLETED = (Date.current - 30).iso8601

  setup do
    Ai::FakeProvider.reset!
    ActionMailer::Base.deliveries.clear
  end

  teardown { Ai::FakeProvider.reset! }

  def reread(item, user: users(:manager))
    Imports::Reread.new(item, user:).call
  end

  test "a rejected item goes back to pending with its AI results and review cleared" do
    item = review_item(holder_name_raw: "Jaun Ortis", person_match: :suggested, extracted_text: "=== page 1 ===\nOSHA 30",
      extraction: extraction_with(certificate_entry), provider: "fake", ai_units_used: 140, attempts: 1,
      person_suggestions: [ { "id" => crew_members(:juan_ortiz).id, "name" => "Juan Ortiz", "similarity" => 0.7 } ],
      type_suggestions: [ { "id" => certificate_types(:osha30).id, "name" => "OSHA 30", "similarity" => 1.0 } ],
      proposed_expires_on: Date.current + 300, proposed_expires_on_source: :printed, page_range: "1",
      error_message: "The completion date is in the future.", skipped_at: 1.hour.ago, next_attempt_at: 1.day.ago)
    Imports::Reject.new(item, user: users(:manager), reason: "Not a certificate").call
    blob = item.reload.file.blob

    result = nil
    assert_enqueued_with(job: Imports::ExtractTextJob, args: [ item ]) { result = reread(item) }

    assert_same item, result
    assert item.pending?
    assert_equal [ nil ] * 14, [ item.extraction, item.provider, item.holder_name_raw, item.certificate_name_raw, item.issuer_raw,
      item.proposed_certificate_number, item.proposed_completed_on, item.proposed_expires_on, item.proposed_expires_on_source,
      item.matched_crew_member, item.matched_certificate_type, item.confidence, item.page_range, item.error_message ]
    assert_equal [ "unmatched", "unmatched", [], [] ], [ item.person_match, item.type_match, item.person_suggestions, item.type_suggestions ]
    assert_equal [ nil, nil, nil, nil, nil, 0 ],
      [ item.rejection_reason, item.reviewed_by, item.reviewed_at, item.skipped_at, item.next_attempt_at, item.attempts ]
    assert_equal 140, item.ai_units_used, "kept: the next read adds to it"
    assert_nil item.extracted_text, "read from the file again: it may hold only the item's pages"
    assert_equal blob, item.file.blob
    assert item.import_batch.reload.processing?
  end

  test "an item never narrowed to pages keeps its text, so OCR doesn't run again" do
    item = review_item(extracted_text: "=== page 1 ===\nOSHA 30", status: :rejected)

    reread(item)

    assert item.pending?
    assert_equal "=== page 1 ===\nOSHA 30", item.extracted_text
  end

  test "a one-certificate PDF that kept its whole file but had its text cut to its pages is read in full again" do
    pages = [ [ "Cover letter", "Please find attached" ], certificate_lines(name: "Flagger Certification", holder: "Li Chen", completed: COMPLETED),
              certificate_lines(name: "First Aid", holder: "Li Chen", completed: COMPLETED) ]
    # combine_pdf overflows its stack on this (poppler reads it fine), so the pages can't be cut out.
    bytes = synthetic_pdf(pages) + "\n99 0 obj\n#{"[" * 100_000}#{"]" * 100_000}\nendobj\n%%EOF\n"
    entry = certificate_entry(pages: [ 2 ], holder: "Li Chen", code: "FLAGGER", name: "Flagger Certification", completed: COMPLETED)
    item = pdf_item(pages, bytes:, extraction: extraction_with(entry, non_certificate_pages: [ 1, 3 ]))
    blob = item.file.blob
    Imports::ProcessExtractionJob.perform_now(item)
    assert_equal [ "2", blob, [ 2 ] ], [ item.reload.page_range, item.file.blob, Imports::Splitter.page_texts(item.extracted_text).keys ]
    Imports::Reject.new(item, user: users(:manager), reason: "The AI missed the first aid card on page 3").call

    assert Imports::Reread.allowed?(item.reload)
    reread(item)
    perform_enqueued_jobs(only: Imports::ExtractTextJob)

    assert item.reload.extracting?
    assert_equal [ 1, 2, 3 ], Imports::Splitter.page_texts(item.extracted_text).keys
    assert_includes item.extracted_text, "First Aid"
    assert_enqueued_with(job: Imports::AiExtractJob, args: [ item ])
  end

  test "the item is read again end to end, and the batch finishes without a second summary email" do
    pages = [ certificate_lines(name: "OSHA 30-Hour Construction Industry Outreach Training", holder: "Juan A. Ortiz", completed: COMPLETED) ]
    item = pdf_item(pages, extraction: extraction_with(certificate_entry(holder: "Nobody Known", completed: COMPLETED)))
    perform_enqueued_jobs { Imports::ProcessExtractionJob.perform_now(item) }
    assert_equal 1, ActionMailer::Base.deliveries.size
    Imports::Reject.new(item.reload, user: users(:manager), reason: "Wrong person").call
    assert item.import_batch.reload.completed?
    units_before = item.ai_units_used

    perform_enqueued_jobs { reread(item) }

    item.reload
    assert item.needs_review?
    assert_equal [ "Juan A. Ortiz", crew_members(:juan_ortiz), "matched" ], [ item.holder_name_raw, item.matched_crew_member, item.person_match ]
    assert_equal 1, Ai::FakeProvider.calls.size, "one new AI call"
    assert_operator item.ai_units_used, :>, units_before
    assert_equal units_before + Ai::Budget.used_today("fake"), item.ai_units_used
    assert_equal "1", item.page_range
    assert item.import_batch.reload.needs_review?
    assert_equal 1, ActionMailer::Base.deliveries.size, "the batch's summary was already sent"
  end

  test "a failed item whose text was purged is read with OCR again" do
    bytes = synthetic_pdf([ certificate_lines(name: "Flagger Certification", holder: "Li Chen", completed: COMPLETED) ])
    item = pipeline_item(bytes:, filename: "flagger.pdf", content_type: "application/pdf", status: :failed,
      error_message: "AI extraction failed after 3 attempts: boom", extracted_text: nil, attempts: 3)

    reread(item)
    assert item.pending?
    perform_enqueued_jobs(only: Imports::ExtractTextJob)

    assert item.reload.extracting?
    assert_includes item.extracted_text, "Awarded to: Li Chen"
    assert_enqueued_with(job: Imports::AiExtractJob, args: [ item ])
  end

  test "an item the AI found no certificate in can be read again, e.g. by another model" do
    item = image_item(extraction: extraction_with)
    Imports::ProcessExtractionJob.perform_now(item)
    assert_equal Imports::ProcessExtractionJob::NO_CERTIFICATE, item.reload.error_message

    assert Imports::Reread.allowed?(item)
    reread(item)

    assert item.pending?
    assert_nil item.error_message
  end

  test "accepted, duplicate, in-pipeline and file-less items are refused, untouched" do
    accepted = import_items(:accepted_li_flagger)
    duplicate = import_items(:duplicate_li_flagger)
    queued = review_item(original_filename: "crew.zip/queued.jpg")
    failed = review_item(status: :failed, error_message: "OCR failed")
    failed.file.purge # as ImportItem.purge_stale_files! leaves it 30 days later
    refusals = {
      accepted => "Accepted items can't be read again.",
      duplicate => "This is a duplicate of an earlier upload (scan_0001.pdf, batch ##{accepted.import_batch_id}), which is already a certificate.",
      import_batch.import_items.create!(status: :duplicate, sha256: queued.sha256, duplicate_of: queued) =>
        "This is a duplicate of an earlier upload: read the original (queued.jpg, batch ##{import_batch.id}) again instead.",
      review_item(status: :pending) => "This item is already being read.",
      review_item(status: :extracting) => "This item is already being read.",
      import_batch.import_items.create!(status: :rejected, original_filename: "crew.zip/../evil.pdf",
        rejection_reason: "Unsafe path in zip (zip-slip guard): refused") => "This item has no file to read again.",
      failed => "This item has no file to read again (a failed item's file is deleted after 30 days). Upload the file again instead."
    }

    refusals.each do |item, message|
      assert_not Imports::Reread.allowed?(item), item.status
      before = item.reload.attributes
      error = assert_raises(Imports::Reread::NotAllowed, item.status) { reread(item) }
      assert_equal message, error.message
      assert_equal before, item.reload.attributes
    end
    assert_no_enqueued_jobs(only: Imports::ExtractTextJob)
    assert_equal certificates(:li_flagger), accepted.certificate
  end

  test "parts of a multi-certificate PDF are refused, and the accepted part and its certificate are left alone" do
    pages = [
      certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED),
      certificate_lines(name: "Flagger Certification", holder: "Li Chen", completed: COMPLETED)
    ]
    source = pdf_item(pages, extraction: extraction_with(certificate_entry(completed: COMPLETED),
      certificate_entry(pages: [ 2 ], holder: "Li Chen", code: "FLAGGER", name: "Flagger Certification", completed: COMPLETED)))
    Imports::ProcessExtractionJob.perform_now(source)
    part = source.reload.split_items.sole
    certificate = Imports::Accept.new(part, user: users(:manager)).call
    Imports::Reject.new(source, user: users(:manager)).call

    error = assert_raises(Imports::Reread::NotAllowed) { reread(source) }
    assert_equal "This item was cut from a PDF that held more than one certificate, so it can't be read again on its own. " \
      "Upload those pages as a new file to read them again.", error.message
    assert_not Imports::Reread.allowed?(part)
    assert source.reload.rejected?
    assert_equal certificate, part.reload.certificate
    assert_no_enqueued_jobs(only: Imports::ExtractTextJob)
  end

  test "an item narrowed to its own pages of a longer PDF is refused" do
    pages = [ [ "COVER SHEET", "Training records" ], certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED) ]
    item = pdf_item(pages, extraction: extraction_with(certificate_entry(pages: [ 2 ], completed: COMPLETED), non_certificate_pages: [ 1 ]))
    Imports::ProcessExtractionJob.perform_now(item)
    assert_equal [ "2", "ortiz p2.pdf" ], [ item.reload.page_range, item.file.filename.to_s ]

    assert_not Imports::Reread.allowed?(item)
    assert_equal "This item's file was cut down to the page its certificate is on (page 2 of the uploaded PDF), so it " \
      "can't be read again on its own. Fill in its fields by hand instead.", assert_raises(Imports::Reread::NotAllowed) { reread(item) }.message
    Imports::Reject.new(item, user: users(:manager)).call
    assert_equal "This item's file was cut down to the page its certificate is on (page 2 of the uploaded PDF), so it " \
      "can't be read again on its own. Upload those pages as a new file to read them again.", Imports::Reread.refusal(item.reload)

    whole = pdf_item([ pages.last ], extraction: extraction_with(certificate_entry(completed: COMPLETED)))
    Imports::ProcessExtractionJob.perform_now(whole)
    assert_equal "1", whole.reload.page_range
    assert Imports::Reread.allowed?(whole), "a one-page PDF is still the whole file"
  end

  test "an item narrowed to its pages is refused when its zip entry's name has characters Active Storage replaces" do
    pages = [ [ "COVER SHEET", "Training records" ], certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED) ]
    # Backslash folders (Windows PowerShell's Compress-Archive), ":" and "%", and a leading space.
    { "crew.zip/cards\\ortiz.pdf" => "cards-ortiz p2.pdf", "crew.zip/Ortiz: OSHA.pdf" => "Ortiz- OSHA p2.pdf",
      "crew.zip/50% ortiz.pdf" => "50- ortiz p2.pdf", "crew.zip/ ortiz.pdf" => "ortiz p2.pdf" }.each do |filename, stored|
      item = pdf_item(pages, filename:, extraction: extraction_with(certificate_entry(pages: [ 2 ], completed: COMPLETED), non_certificate_pages: [ 1 ]))
      Imports::ProcessExtractionJob.perform_now(item)
      assert_equal [ "2", stored, 1 ], [ item.reload.page_range, item.file.filename.to_s, pdf_page_count(item.file.blob) ], filename
      Imports::Reject.new(item, user: users(:manager)).call

      assert_equal "This item's file was cut down to the page its certificate is on (page 2 of the uploaded PDF), so it " \
        "can't be read again on its own. Upload those pages as a new file to read them again.", Imports::Reread.refusal(item.reload), filename
      assert_raises(Imports::Reread::NotAllowed, filename) { reread(item) }
      assert_equal "2", item.reload.page_range, filename
    end
    assert_no_enqueued_jobs(only: Imports::ExtractTextJob)
  end

  test "a failed item whose file was uploaded again later is refused in favor of that copy" do
    bytes = "same-bytes-#{SecureRandom.hex(4)}"
    failed = review_item(bytes:, status: :failed, error_message: "OCR failed")
    later_batch = ImportBatch.create!(uploaded_by: users(:admin), status: :needs_review)
    review_item(bytes:, import_batch: later_batch)

    error = assert_raises(Imports::Reread::NotAllowed) { reread(failed) }
    assert_equal "This file was uploaded again later (batch ##{later_batch.id}): read that copy again instead.", error.message
  end

  test "a context looked up for a whole page of items gives every item the same answer, without a query per item" do
    pages = [
      certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED),
      certificate_lines(name: "Flagger Certification", holder: "Li Chen", completed: COMPLETED)
    ]
    source = pdf_item(pages, extraction: extraction_with(certificate_entry(completed: COMPLETED),
      certificate_entry(pages: [ 2 ], holder: "Li Chen", code: "FLAGGER", name: "Flagger Certification", completed: COMPLETED)))
    Imports::ProcessExtractionJob.perform_now(source)
    Imports::Reject.new(source.reload, user: users(:manager)).call
    part = source.split_items.sole
    Imports::Reject.new(part, user: users(:manager)).call
    bytes = "same-bytes-#{SecureRandom.hex(4)}"
    uploaded_again = review_item(bytes:, status: :failed, error_message: "OCR failed")
    review_item(bytes:, import_batch: ImportBatch.create!(uploaded_by: users(:admin), status: :needs_review))
    failed = review_item(status: :failed, error_message: "OCR failed")
    rejected = review_item(status: :rejected, rejection_reason: "Not a certificate")
    items = ImportItem.where(id: [ source, part, uploaded_again, failed, rejected, import_items(:accepted_li_flagger) ].map(&:id))
      .order(:id).with_attached_file.to_a
    expected = items.map { |item| Imports::Reread.refusal(item) }

    context = nil
    assert_equal 2, count_queries { context = Imports::Reread.context_for(items) }
    answers = nil
    assert_equal 0, count_queries { answers = items.map { |item| Imports::Reread.refusal(item, context:) } }

    assert_equal expected, answers
    assert_equal [ failed, rejected ].map(&:id), items.select { |item| Imports::Reread.allowed?(item, context:) }.map(&:id)
    assert_equal 0, count_queries { Imports::Reread.context_for(items.select(&:accepted?)) }, "nothing to look up"
  end

  test "a context answers for an item it wasn't looked up for by asking the database" do
    source = review_item(status: :rejected)
    ImportItem.create!(import_batch: import_batch, source_item: source, status: :rejected, sha256: source.sha256,
      original_filename: source.original_filename, page_range: "2")
    context = Imports::Reread.context_for([ review_item(status: :rejected) ])

    assert_not Imports::Reread.allowed?(source, context:)
    assert_match "more than one certificate", Imports::Reread.refusal(source, context:)
  end

  test "a second click, from a page that still shows the old status, enqueues nothing more" do
    item = review_item
    stale = ImportItem.find(item.id)

    reread(item)
    error = assert_raises(Imports::Reread::NotAllowed) { reread(stale) }

    assert_equal "This item is already being read.", error.message
    assert_enqueued_jobs 1, only: Imports::ExtractTextJob
  end

  test "racing clicks read the item once" do
    item = review_item
    copies = Array.new(4) { ImportItem.find(item.id) }

    threads = copies.map do |copy|
      Thread.new do
        reread(copy)
        :read
      rescue Imports::Reread::NotAllowed
        :refused
      end
    end

    assert_equal %i[read refused refused refused], threads.map(&:value).sort
    assert_enqueued_jobs 1, only: Imports::ExtractTextJob
    assert item.reload.pending?
  end

  test "a deleted item is refused" do
    item = review_item
    stale = ImportItem.find(item.id)
    item.destroy!

    assert_equal "This item no longer exists.", assert_raises(Imports::Reread::NotAllowed) { reread(stale) }.message
  end

  private
    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ActiveRecord::Base.uncached(&block) }
      count
    end
end
