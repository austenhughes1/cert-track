require "test_helper"
require_relative "../../services/imports/match_test_support"

class Imports::ProcessExtractionJobTest < ActiveJob::TestCase
  include ImportsMatchTestSupport

  COMPLETED = (Date.current - 30).iso8601

  def ortiz_osha(**overrides)
    certificate_entry(pages: [ 1 ], holder: "Juan A. Ortiz", code: "OSHA30", completed: COMPLETED, **overrides)
  end

  def process(item)
    Imports::ProcessExtractionJob.perform_now(item)
    item.reload
  end

  test "one photo, hand-written extraction: proposals filled in and queued for review" do
    item = image_item(extraction: extraction_with(ortiz_osha(confidence: 0.92, number: " 30-1234567 ")))

    process(item)

    assert item.needs_review?
    assert_equal [ "Juan A. Ortiz", "OSHA 30-Hour Construction Industry Outreach Training", "Example Safety Training LLC", "30-1234567" ],
      [ item.holder_name_raw, item.certificate_name_raw, item.issuer_raw, item.proposed_certificate_number ]
    assert_equal BigDecimal("0.92"), item.confidence
    assert_equal [ crew_members(:juan_ortiz), "matched" ], [ item.matched_crew_member, item.person_match ]
    assert_equal [ certificate_types(:osha30), "matched" ], [ item.matched_certificate_type, item.type_match ]
    assert_equal crew_members(:juan_ortiz).id, item.person_suggestions.first["id"]
    assert_equal certificate_types(:osha30).id, item.type_suggestions.first["id"]
    assert_equal Date.parse(COMPLETED), item.proposed_completed_on
    assert_nil item.proposed_expires_on
    assert item.proposed_expiry_none?
    assert_nil item.page_range
    assert_nil item.error_message
    assert_nil item.certificate

    batch = item.import_batch.reload
    assert batch.needs_review?
    assert_equal 1, batch.review_count
    assert_not_nil batch.summary_sent_at
  end

  test "auto-accept on: a clean extraction becomes a certificate" do
    item = image_item(extraction: extraction_with(ortiz_osha))

    certificate_count = Certificate.count
    with_auto_accept { process(item) }

    assert item.accepted?
    certificate = item.certificate
    assert_equal certificate_count + 1, Certificate.count
    assert certificate.source_import?
    assert_equal [ crew_members(:juan_ortiz), certificate_types(:osha30), Date.parse(COMPLETED) ],
      [ certificate.crew_member, certificate.certificate_type, certificate.completed_on ]
    assert certificate.expiry_none?
    assert_nil certificate.verified_by
    assert_equal [ item.file.blob ], certificate.files.blobs.to_a
    assert certificates(:juan_osha30).reload.superseded?
    assert item.import_batch.reload.completed?
  end

  test "auto-accept on still reviews a suggestion" do
    item = image_item(extraction: extraction_with(ortiz_osha(holder: "Juan Ortis")))

    with_auto_accept { process(item) }

    assert item.needs_review?
    assert item.person_suggested?
    assert_equal crew_members(:juan_ortiz), item.matched_crew_member
  end

  test "date problems are kept for the reviewer and block auto-accept" do
    item = image_item(extraction: extraction_with(ortiz_osha(completed: (Date.current + 5).iso8601)))

    with_auto_accept { process(item) }

    assert item.needs_review?
    assert_equal "The completion date #{(Date.current + 5).iso8601} is in the future.", item.error_message
    assert_equal Date.current + 5, item.proposed_completed_on
  end

  test "a computed expiry is proposed from the type's validity" do
    item = image_item(extraction: extraction_with(ortiz_osha(code: "FLAGGER", name: "Flagger Certification")))

    process(item)

    assert item.proposed_expiry_computed?
    assert_equal Date.parse(COMPLETED) >> 36, item.proposed_expires_on
  end

  test "a multi-certificate PDF is split; the course outline is left out" do
    pages = [
      certificate_lines(name: "OSHA 30-Hour Construction Industry Outreach Training", holder: "Juan A. Ortiz", completed: COMPLETED),
      [ "COURSE OUTLINE", "Module 1: Fall protection" ],
      certificate_lines(name: "Flagger Certification", holder: "LI CHEN", number: "FL-77", completed: COMPLETED, expires: (Date.current + 900).iso8601)
    ]
    extraction = extraction_with(ortiz_osha,
      certificate_entry(pages: [ 3 ], holder: "LI CHEN", code: "FLAGGER", name: "Flagger Certification", number: "FL-77",
        completed: COMPLETED, expires: (Date.current + 900).iso8601),
      non_certificate_pages: [ 2 ])
    item = pdf_item(pages, extraction:)

    process(item)

    split = item.split_items.sole
    assert_equal [ "1", "3" ], [ item.page_range, split.page_range ]
    assert_equal [ "needs_review", "needs_review" ], [ item.status, split.status ]
    assert_equal [ crew_members(:juan_ortiz), crew_members(:li_chen) ], [ item.matched_crew_member, split.matched_crew_member ]
    assert_equal [ certificate_types(:osha30), certificate_types(:flagger) ], [ item.matched_certificate_type, split.matched_certificate_type ]
    assert split.proposed_expiry_printed?
    assert_equal "FL-77", split.proposed_certificate_number
    assert_equal [ "ortiz p1.pdf", "ortiz p3.pdf" ], [ item.file.filename.to_s, split.file.filename.to_s ]
    assert_includes pdf_text(split.file.blob), "Awarded to: LI CHEN"
    assert_not_includes pdf_text(item.file.blob), "COURSE OUTLINE"
    assert_includes split.extracted_text, "=== page 3 ==="
    assert_equal 2, item.import_batch.reload.review_count
    assert_equal extraction, item.extraction
  end

  test "auto-accepted split pages carry their own uploaded page file" do
    pages = [
      certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED),
      certificate_lines(name: "Flagger Certification", holder: "Li Chen", completed: COMPLETED)
    ]
    item = pdf_item(pages, extraction: extraction_with(ortiz_osha,
      certificate_entry(pages: [ 2 ], holder: "Li Chen", code: "FLAGGER", name: "Flagger Certification", completed: COMPLETED)))

    with_auto_accept { process(item) }

    [ item, item.split_items.sole ].each do |accepted|
      assert accepted.accepted?
      blob = accepted.certificate.files.blobs.sole
      assert_equal accepted.file.blob, blob
      assert blob.service.exist?(blob.key), "#{blob.filename} was not uploaded"
      assert_equal 1, pdf_page_count(blob)
    end
    assert_includes pdf_text(item.split_items.sole.certificate.files.blobs.sole), "Li Chen"
    assert item.split_items.sole.certificate.expiry_computed?
  end

  test "a page range that already came in earlier is a duplicate" do
    pages = [ certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED) ]
    earlier_batch = ImportBatch.create!(uploaded_by: users(:admin), status: :completed)
    bytes = synthetic_pdf(pages)
    earlier = pdf_item(pages, bytes:, extraction: nil, batch: earlier_batch, status: :accepted, page_range: "1")
    item = pdf_item(pages, bytes:, extraction: extraction_with(ortiz_osha))

    process(item)

    assert item.duplicate?
    assert_equal earlier, item.duplicate_of
    assert_nil item.holder_name_raw
    assert item.import_batch.reload.completed?
  end

  test "earlier failed or duplicate items are not originals" do
    pages = [ certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED) ]
    bytes = synthetic_pdf(pages)
    pdf_item(pages, bytes:, extraction: nil, status: :failed, page_range: "1")
    pdf_item(pages, bytes:, extraction: nil, status: :duplicate, page_range: "1")
    item = pdf_item(pages, bytes:, extraction: extraction_with(ortiz_osha))

    process(item)

    assert item.needs_review?
  end

  test "no certificate found: a person confirms it in the review queue, even with auto-accept on" do
    item = pdf_item([ [ "COURSE OUTLINE" ] ], extraction: extraction_with(non_certificate_pages: [ 1 ]))

    with_auto_accept { process(item) }

    assert item.needs_review?, "a free model can miss a real card, so it is never rejected unseen"
    assert_equal Imports::ProcessExtractionJob::NO_CERTIFICATE, item.error_message
    assert_nil item.rejection_reason
    assert_includes ImportItem.review_queue, item
    assert_equal [ 1 ], item.extraction["non_certificate_pages"]
    assert_nil item.page_range
    assert item.import_batch.reload.needs_review?
  end

  test "a certificate the model missed can still be accepted from the review queue" do
    item = image_item(extraction: extraction_with)
    process(item)

    certificate = Imports::Accept.new(item, user: users(:manager), attributes: {
      crew_member_id: crew_members(:juan_ortiz).id, certificate_type_id: certificate_types(:osha30).id, completed_on: COMPLETED
    }).call

    assert item.reload.accepted?
    assert_equal [ crew_members(:juan_ortiz), [ item.file.blob ] ], [ certificate.crew_member, certificate.files.blobs.to_a ]
  end

  test "a later upload of a file the model found nothing in points at the queued item, not a silent rejection" do
    first = pdf_item([ [ "COURSE OUTLINE" ] ], extraction: extraction_with(non_certificate_pages: [ 1 ]))
    process(first)

    assert_equal first, ImportItem.original_file_for(first.sha256)
    assert first.needs_review?, "the original is still waiting for a person, so nothing is lost"
  end

  test "no extraction at all fails the item" do
    item = image_item(extraction: nil)

    process(item)

    assert item.failed?
    assert_equal "There is no AI extraction to process.", item.error_message
    assert item.import_batch.reload.failed?
  end

  test "an unreadable printed expiry is reported for review, never replaced by a computed one" do
    raw = ortiz_osha(code: "FLAGGER", name: "Flagger Certification", expires: "2027-06", confidence: 0.95) # "EXP 06/2027"
    item = image_item(extraction: normalized(raw))
    assert_nil item.extraction["certificates"].sole["expires_on"]

    with_auto_accept { process(item) }

    assert item.needs_review?
    assert_nil item.certificate
    assert_nil item.proposed_expires_on, "no Flagger expiry computed from the completion date"
    assert_nil item.proposed_expires_on_source
    assert_equal 'The expiration date "2027-06" is not a valid YYYY-MM-DD date.', item.error_message
    assert_equal [ crew_members(:juan_ortiz), "matched" ], [ item.matched_crew_member, item.person_match ]
  end

  test "an unreadable completion date is reported for review" do
    item = image_item(extraction: normalized(ortiz_osha(completed: "03/14/2025")))

    with_auto_accept { process(item) }

    assert item.needs_review?
    assert_nil item.proposed_completed_on
    assert_equal 'The completion date "03/14/2025" is not a valid YYYY-MM-DD date.', item.error_message
  end

  test "a model confidence of 0.846 does not pass the 0.85 auto-accept threshold" do
    item = image_item(extraction: normalized(ortiz_osha(confidence: 0.846)))

    with_auto_accept { process(item) }

    assert_equal 0.84, item.extraction["certificates"].sole["confidence"]
    assert_equal BigDecimal("0.84"), item.confidence
    assert item.needs_review?
  end

  test "a PDF that overflows combine_pdf's stack keeps the whole file on each item instead of sticking" do
    pages = [ certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED),
              certificate_lines(name: "Flagger Certification", holder: "Li Chen", completed: COMPLETED) ]
    bytes = synthetic_pdf(pages) + "\n99 0 obj\n#{"[" * 100_000}#{"]" * 100_000}\nendobj\n%%EOF\n"
    item = pdf_item(pages, bytes:, extraction: extraction_with(ortiz_osha,
      certificate_entry(pages: [ 2 ], holder: "Li Chen", code: "FLAGGER", name: "Flagger Certification", completed: COMPLETED)))
    blob = item.file.blob

    process(item)

    family = [ item, item.split_items.sole ]
    assert_equal [ "needs_review", "needs_review" ], family.map(&:status)
    assert_equal [ "1", "2" ], family.map(&:page_range)
    assert_equal [ blob, blob ], family.map { _1.file.blob }
    assert item.import_batch.reload.needs_review?
  end

  test "a stack overflow anywhere in processing fails the item at once and finishes the batch" do
    item = image_item(extraction: extraction_with(ortiz_osha))

    with_stack_overflow_in(Imports::Splitter) do
      assert_nothing_raised { process(item) }
    end

    assert item.failed?
    assert_equal "Could not process the AI extraction: SystemStackError: stack level too deep", item.error_message
    assert item.import_batch.reload.failed?
    assert_no_enqueued_jobs only: Imports::ProcessExtractionJob
  end

  test "confidence is clamped and rounded down, junk values ignored" do
    { 0.849 => BigDecimal("0.84"), 1.7 => BigDecimal("1"), -1 => BigDecimal("0"), "0.9" => BigDecimal("0.9"), "high" => nil, nil => nil }.each do |raw, expected|
      item = image_item(extraction: extraction_with(ortiz_osha(confidence: raw)), sha256: SecureRandom.hex(32))

      process(item)

      expected.nil? ? assert_nil(item.confidence, raw.inspect) : assert_equal(expected, item.confidence, raw.inspect)
    end
  end

  test "an auto-accept the certificate refuses goes to review with the reason" do
    item = pipeline_item(bytes: "not a certificate file", filename: "notes.txt", content_type: "text/plain",
      extraction: extraction_with(ortiz_osha))

    with_auto_accept { process(item) }

    assert item.needs_review?
    assert_match(/\AAuto-accept was refused: Files notes.txt must be a PDF/, item.error_message)
    assert_nil item.certificate
    assert_equal [], Certificate.where(import_item: item).to_a
  end

  test "running twice does nothing the second time" do
    item = pdf_item([ certificate_lines(name: "a", holder: "b"), certificate_lines(name: "c", holder: "d") ],
      extraction: extraction_with(ortiz_osha, ortiz_osha(pages: [ 2 ])))

    process(item)
    assert_no_changes -> { [ ImportItem.count, item.reload.updated_at ] } do
      process(item)
    end
    assert_equal 1, item.split_items.count
  end

  test "items already past the pipeline are left alone" do
    item = review_item
    item.update!(extraction: extraction_with(ortiz_osha))

    assert_no_changes -> { item.reload.attributes } do
      process(item)
    end
  end

  test "fail_item fails an item still in the pipeline and leaves a processed one alone" do
    processed = review_item
    Imports::ProcessExtractionJob.new.fail_item(processed, RuntimeError.new("boom"))
    assert processed.reload.needs_review?

    stuck = image_item(extraction: nil)
    Imports::ProcessExtractionJob.new.fail_item(stuck, RuntimeError.new("boom"))
    assert stuck.reload.failed?
    assert_equal "Could not process the AI extraction: RuntimeError: boom", stuck.error_message
  end

  test "a storage error is retried, then the item fails with the message" do
    item = pdf_item([ certificate_lines(name: "a", holder: "b") ], extraction: extraction_with(ortiz_osha))
    item.file.blob.service.delete(item.file.blob.key)

    perform_enqueued_jobs(only: Imports::ProcessExtractionJob) do
      Imports::ProcessExtractionJob.perform_later(item)
    end

    assert item.reload.failed?
    assert_match(/\ACould not process the AI extraction: ActiveStorage::FileNotFoundError/, item.error_message)
    assert_nil item.page_range
    assert_equal 0, item.split_items.count
    assert item.import_batch.reload.failed?
  end

  private
    # The extraction AiExtractJob would store for these model certificates (string keys).
    def normalized(*certificates)
      Imports::Extraction::Normalizer.new(pages: [ 1 ], codes: CertificateType.active.pluck(:code))
        .call("certificates" => certificates, "non_certificate_pages" => [])
    end

    # klass.new raises SystemStackError inside the block, like a parser recursing on a hostile file.
    def with_stack_overflow_in(klass)
      klass.define_singleton_method(:new) { |*| raise SystemStackError, "stack level too deep" }
      yield
    ensure
      klass.singleton_class.remove_method(:new)
    end
end
