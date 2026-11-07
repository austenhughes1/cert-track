require "test_helper"
require "support/import_samples"
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
    blob = item.file.blob

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
    assert_equal [ blob ], certificate.files.blobs.to_a
    assert_not item.file.attached?, "the certificate holds the file now"
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
      assert_not accepted.file.attached?, "the certificate holds the file now"
      assert_equal [ accepted.certificate ], ActiveStorage::Attachment.where(blob_id: blob.id).map(&:record)
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
    blob = item.file.blob

    certificate = Imports::Accept.new(item, user: users(:manager), attributes: {
      crew_member_id: crew_members(:juan_ortiz).id, certificate_type_id: certificate_types(:osha30).id, completed_on: COMPLETED
    }).call

    assert item.reload.accepted?
    assert_equal [ crew_members(:juan_ortiz), [ blob ] ], [ certificate.crew_member, certificate.files.blobs.to_a ]
  end

  test "a PDF uploaded on its own and split into its certificates leaves no whole copy behind" do
    pages = [
      certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED),
      certificate_lines(name: "Flagger Certification", holder: "Li Chen", completed: COMPLETED)
    ]
    batch = ImportSamples.batch(users(:manager), "two cards.pdf" => synthetic_pdf(pages))
    whole = batch.uploads.sole.blob
    Imports::ExpandJob.perform_now(batch)
    item = batch.import_items.sole
    assert_equal whole, item.file.blob, "the upload's blob is the item's file until it is split"
    item.update!(status: :extracting, extracted_text: marked_text(pages), extraction: extraction_with(ortiz_osha,
      certificate_entry(pages: [ 2 ], holder: "Li Chen", code: "FLAGGER", name: "Flagger Certification", completed: COMPLETED)))

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { process(item) }

    assert_not ActiveStorage::Blob.exists?(whole.id)
    assert_not whole.service.exist?(whole.key)
    family = [ item, item.split_items.sole ]
    assert_equal [ "two cards p1.pdf", "two cards p2.pdf" ], family.map { |part| part.file.filename.to_s }
    assert_equal family.map { |part| part.file.blob }.sort_by(&:id), ActiveStorage::Blob.order(:id).to_a
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
    assert_equal "2027-06", item.unreadable_expires_on

    error = assert_raises(ActiveRecord::RecordInvalid) { Imports::Accept.new(item, user: users(:manager)).call }
    assert_equal [ %(The card's expiry ("2027-06") could not be read. Type the expiry date from the card.) ],
      error.record.errors.full_messages
  end

  test "auto-accept never takes an unreadable printed expiry, even when the decider would" do
    raw = ortiz_osha(expires: "06/2027", confidence: 0.99) # OSHA 30 never expires: no other rule fails
    item = image_item(extraction: normalized(raw))

    with_decider_saying(:accept) { with_auto_accept { process(item) } }

    assert item.needs_review?
    assert_nil item.certificate
    assert_equal %(Auto-accept was refused: The card's expiry ("06/2027") could not be read. Type the expiry date from the card.),
      item.error_message
    assert_empty Certificate.where(import_item_id: item.id)
  end

  test "a card that says it never expires has no expiration, and isn't an unreadable expiry" do
    item = image_item(extraction: normalized(ortiz_osha(expires: "Does not expire")))

    process(item)

    assert item.needs_review?
    assert item.proposed_expiry_no_expiration?
    assert_nil item.error_message
    assert_nil item.unreadable_expires_on
    certificate = Imports::Accept.new(item, user: users(:manager), attributes: { expires_on: "" }).call # left blank on the form
    assert certificate.expiry_no_expiration?
    assert_nil certificate.expires_on

    lifetime = image_item(filename: "flagger.jpg", sha256: SecureRandom.hex(32),
      extraction: normalized(ortiz_osha(code: "FLAGGER", name: "Flagger Certification", expires: "Lifetime")))
    with_auto_accept { process(lifetime) }
    assert lifetime.accepted?, lifetime.error_message
    assert lifetime.certificate.expiry_no_expiration?, "the card says so, whatever Flagger's 36 months say"
    assert_nil lifetime.certificate.expires_on
  end

  test "a blank verification code falls back to the certificate number when the issuer looks up by code" do
    CertificateIssuer.seed_defaults!
    blank = ortiz_osha(number: "5B1", issuer: "National CPR Foundation", issuer_code: "NCPRF")
    item = process(image_item(extraction: extraction_with(blank)))
    assert_equal "5B1", item.proposed_verification_code

    typed = ortiz_osha(number: "5B1", issuer: "National CPR Foundation", issuer_code: "NCPRF", verification_code: "CODE9")
    assert_equal "CODE9", process(image_item(filename: "typed.jpg", sha256: SecureRandom.hex(32), extraction: extraction_with(typed))).proposed_verification_code

    no_issuer = ortiz_osha(number: "26-007689462", issuer: "OSHA")
    assert_nil process(image_item(filename: "osha.jpg", sha256: SecureRandom.hex(32), extraction: extraction_with(no_issuer))).proposed_verification_code
  end

  test "an unread QR code and unread details flag the item for a clearer copy, and a clean one isn't flagged" do
    clean = process(image_item(extraction: normalized(ortiz_osha)))
    assert_equal [], clean.quality_flags

    qr = process(image_item(filename: "qr.jpg", sha256: SecureRandom.hex(32), unread_qr_pages: [ 1 ], extraction: normalized(ortiz_osha)))
    assert_equal [ "qr_unreadable" ], qr.quality_flags

    nameless = process(image_item(filename: "blur.jpg", sha256: SecureRandom.hex(32), extraction: normalized(ortiz_osha(holder: nil))))
    assert_equal [ "hard_to_read" ], nameless.quality_flags
  end

  test "expiry rule: a printed period, the type's validity, the 2-year default, and OSHA's none" do
    entry = ->(**overrides) { ortiz_osha(code: "FLAGGER", name: "Flagger Certification", **overrides) }
    propose = lambda do |certificate, sha|
      process(image_item(filename: "#{sha}.jpg", sha256: SecureRandom.hex(32), extraction: normalized(certificate)))
    end

    period = propose.call(entry.call.merge("validity_months" => 12), "period")
    assert period.proposed_expiry_printed_period?
    assert_equal Date.parse(COMPLETED) >> 12, period.proposed_expires_on

    from_type = propose.call(entry.call, "type")
    assert from_type.proposed_expiry_computed?
    assert_equal Date.parse(COMPLETED) >> 36, from_type.proposed_expires_on

    no_type = propose.call(ortiz_osha(code: nil, name: "Bloodborne Pathogens Training"), "unlisted")
    assert no_type.proposed_expiry_computed?
    assert_equal Date.parse(COMPLETED) >> 24, no_type.proposed_expires_on

    osha = propose.call(ortiz_osha, "osha")
    assert osha.proposed_expiry_none?
    assert_nil osha.proposed_expires_on
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

  # --- Phase 3b: issuers, verification code and link, authenticity --------------------------

  REDCROSS_QR = "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123".freeze

  test "a two-certificate PDF with a QR code on page 2: the second item gets it and its issuer by domain" do
    pages = [
      certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz", completed: COMPLETED),
      certificate_lines(name: "Adult First Aid CPR AED", holder: "Li Chen", completed: COMPLETED, issuer: "Red Cross Training")
    ]
    issuer("REDCROSS")
    item = pdf_item(pages, barcodes: [ { "page" => 2, "text" => REDCROSS_QR } ], extraction: extraction_with(ortiz_osha,
      certificate_entry(pages: [ 2 ], holder: "Li Chen", code: "FIRSTAID", name: "Adult First Aid CPR AED", completed: COMPLETED,
        issuer: "Red Cross Training")))

    process(item)
    split = item.split_items.sole

    assert_equal [], item.barcodes
    assert_equal [ "Example Safety Training LLC", "matched", nil, nil ], [ item.matched_certificate_issuer.name, item.issuer_match,
      item.proposed_verification_code, item.proposed_verification_url ], "an issuer nothing matches is added from the card"
    assert_equal [ { "page" => 1, "text" => REDCROSS_QR } ], split.barcodes, "page 2 of the upload is page 1 of its own file"
    assert_equal [ issuer("REDCROSS"), "matched" ], [ split.matched_certificate_issuer, split.issuer_match ]
    assert_equal issuer("REDCROSS").id, split.issuer_suggestions.first["id"]
    assert_equal [ "TEST123", REDCROSS_QR ], [ split.proposed_verification_code, split.proposed_verification_url ]
    assert_equal "Red Cross Training", split.issuer_raw
  end

  test "the model's issuer code and printed code give the issuer's direct link; a printed link wins over it" do
    item = image_item(extraction: extraction_with(ortiz_osha(issuer: "American Red Cross", issuer_code: "redcross", verification_code: "RC 77")))
    printed = image_item(sha256: SecureRandom.hex(32), extraction: extraction_with(ortiz_osha(issuer_code: "REDCROSS",
      verification_code: "RC-1", verification_url: "redcross.org/confirm")))
    issuer("REDCROSS")

    process(item)
    process(printed)

    assert_equal [ issuer("REDCROSS"), "matched", "RC 77" ],
      [ item.matched_certificate_issuer, item.issuer_match, item.proposed_verification_code ]
    assert_equal "https://www.redcross.org/take-a-class/qrcode?certnumber=RC%2077", item.proposed_verification_url
    assert_equal [ "RC-1", "https://redcross.org/confirm" ], [ printed.proposed_verification_code, printed.proposed_verification_url ]
  end

  test "the model's code wins over the id in the QR link; a QR link on another site is no issuer's" do
    issuer("REDCROSS")
    item = image_item(barcodes: [ { "page" => 1, "text" => REDCROSS_QR } ],
      extraction: extraction_with(ortiz_osha(verification_code: "PRINTED-1")))
    lookalike = image_item(sha256: SecureRandom.hex(32), barcodes: [ { "page" => 1, "text" => "https://redcross-verify.com/c?certnumber=X9" } ],
      extraction: extraction_with(ortiz_osha))

    process(item)
    process(lookalike)

    assert_equal [ "PRINTED-1", REDCROSS_QR ], [ item.proposed_verification_code, item.proposed_verification_url ]
    assert_equal [ "Example Safety Training LLC", "matched", nil, nil ], [ lookalike.matched_certificate_issuer.name, lookalike.issuer_match,
      lookalike.proposed_verification_code, lookalike.proposed_verification_url ]
    assert_equal 1, lookalike.barcodes.size, "kept for the authenticity rules"
  end

  test "a printed link on another site gives way to the matched issuer's own link; a printed lookalike is kept and flagged" do
    issuer("REDCROSS")
    elsewhere = image_item(extraction: extraction_with(ortiz_osha(issuer_code: "REDCROSS", verification_code: "RC-1",
      verification_url: "https://records.example-training.com/c/1")))
    lookalike = image_item(sha256: SecureRandom.hex(32), extraction: extraction_with(ortiz_osha(issuer_code: "REDCROSS",
      verification_code: "RC-1", verification_url: "https://www.redcross-verify.com/c/12345")))
    unknown = image_item(sha256: SecureRandom.hex(32), extraction: extraction_with(ortiz_osha(verification_code: "RC-1",
      verification_url: "https://records.example-training.com/c/1")))

    [ elsewhere, lookalike, unknown ].each { |item| process(item) }

    assert_equal "https://www.redcross.org/take-a-class/qrcode?certnumber=RC-1", elsewhere.proposed_verification_url
    assert_equal "https://www.redcross-verify.com/c/12345", lookalike.proposed_verification_url
    assert lookalike.authenticity_suspicious?, "so it is never auto-accepted, and the panel doesn't link it"
    assert_equal "https://records.example-training.com/c/1", unknown.proposed_verification_url, "no issuer link to prefer"
  end

  test "several of the issuer's QR codes on one photo: the one with the certificate's code or number, else the holder's, else none" do
    issuer("REDCROSS")
    other = "https://www.redcross.org/take-a-class/qrcode?certnumber=OTHER456"
    training = "https://verify.360training.com/qrcode-certificate-validation?enrollmentId=%s&s_fname=%s&s_lname=%s&issued=03/14/2025"
    juans, marias = format(training, "111", "Juan", "Ortiz"), format(training, "222", "Maria", "Garcia")
    cases = {
      "by code" => [ [ other, REDCROSS_QR ], ortiz_osha(verification_code: "TEST123"), [ "TEST123", REDCROSS_QR ] ],
      "by number" => [ [ other, REDCROSS_QR ], ortiz_osha(number: "test123"), [ "TEST123", REDCROSS_QR ] ],
      "by holder" => [ [ marias, juans ], ortiz_osha(issuer_code: "360TRAINING"), [ "111", juans ] ],
      "can't tell which link: the issuer's own, for the printed number" => [ [ other, REDCROSS_QR ], ortiz_osha, [ "30-1234567", issuer("REDCROSS").link_for("30-1234567") ] ]
    }

    cases.each do |label, (texts, certificate, expected)|
      item = image_item(sha256: SecureRandom.hex(32), barcodes: texts.map { |text| { "page" => 1, "text" => text } },
        extraction: extraction_with(certificate))

      process(item)

      assert_equal expected, [ item.proposed_verification_code, item.proposed_verification_url ], label
      assert item.issuer_matched?, label
    end
  end

  test "an item the issuer's site will be asked about waits for review, even when it would be auto-accepted" do
    item = image_item(extraction: extraction_with(ortiz_osha(issuer_code: "NOF", verification_code: "NOF-1")))
    issuer("NOF")

    Verification::Config.with(auto_checks: true) do
      with_auto_accept { assert_enqueued_with(job: Verification::CheckJob, args: [ item ]) { process(item) } }
    end

    assert item.needs_review?
    assert_nil item.certificate
    with_auto_accept do
      assert_equal [ "The issuer's site hasn't been asked yet" ], Imports::Decider.new(item, issuer_check_pending: true).reasons
      assert_empty Imports::Decider.new(item).reasons
    end

    plain = image_item(sha256: SecureRandom.hex(32), extraction: extraction_with(ortiz_osha(issuer_code: "NOF", verification_code: "NOF-1")))
    with_auto_accept { process(plain) }
    assert plain.accepted?, "with automatic checks off nothing is asked, so nothing is waited for"
  end

  test "a printed name only suggests an issuer, and its link template is not used" do
    issuer("REDCROSS")
    item = image_item(extraction: extraction_with(ortiz_osha(issuer: "American Red Cros", verification_code: "RC-1")))

    process(item)

    assert_equal [ issuer("REDCROSS"), "suggested" ], [ item.matched_certificate_issuer, item.issuer_match ]
    assert_equal [ "RC-1", nil ], [ item.proposed_verification_code, item.proposed_verification_url ]
  end

  test "authenticity is checked with local rules only, before deciding, and carried to an auto-accepted certificate" do
    item = image_item(extraction: extraction_with(ortiz_osha))

    with_verification_run(status: :needs_check) do |calls|
      with_auto_accept { process(item) }

      assert_equal [ [ item.id, { network: false } ] ], calls
    end
    assert item.accepted?
    assert_equal [ "needs_check", "rules", "Set by the test." ],
      [ item.certificate.authenticity_status, item.certificate.authenticity_method, item.certificate.authenticity_note ]
  end

  test "a flagged item is never auto-accepted" do
    Authenticity::FLAGGED_STATUSES.each do |status|
      item = image_item(sha256: SecureRandom.hex(32), extraction: extraction_with(ortiz_osha))

      with_verification_run(status:) { with_auto_accept { process(item) } }

      assert item.needs_review?, status
      assert_nil item.certificate, status
      assert_equal status, item.authenticity_status
    end
  end

  test "an issuer whose site can confirm the code is asked once the item is saved, when automatic checks are on" do
    item = image_item(extraction: extraction_with(ortiz_osha(issuer_code: "NOF", verification_code: "NOF-1")))
    issuer("NOF")

    Verification::Config.with(auto_checks: true) do
      assert_enqueued_with(job: Verification::CheckJob, args: [ item ]) { process(item) }
    end
    assert_equal "NOF-1", item.proposed_verification_code
  end

  test "no issuer check is enqueued with checks off, without a code, for an assisted issuer or a suggested one" do
    issuer("NOF")
    items = {
      "checks off" => [ false, ortiz_osha(issuer_code: "NOF", verification_code: "NOF-1") ],
      "no code" => [ true, ortiz_osha(issuer_code: "NOF", number: nil) ],
      "assisted issuer" => [ true, ortiz_osha(issuer_code: "REDCROSS", verification_code: "RC-1") ],
      "suggested issuer" => [ true, ortiz_osha(issuer: "National OSHA Foundatoin", verification_code: "NOF-1") ]
    }

    items.each do |label, (checks, certificate)|
      item = image_item(sha256: SecureRandom.hex(32), extraction: extraction_with(certificate))
      Verification::Config.with(auto_checks: checks) do
        assert_no_enqueued_jobs(only: Verification::CheckJob) { process(item) }
      end
      assert item.needs_review?, label
    end
    assert_equal "suggested", ImportItem.order(:id).last.issuer_match
  end

  private
    # The extraction AiExtractJob would store for these model certificates (string keys).
    def normalized(*certificates)
      Imports::Extraction::Normalizer.new(pages: [ 1 ], codes: CertificateType.active.pluck(:code))
        .call("certificates" => certificates, "non_certificate_pages" => [])
    end

    # Imports::Decider answers decision for every item inside the block.
    def with_decider_saying(decision)
      Imports::Decider.define_singleton_method(:new) { |*| Struct.new(:call).new(decision) }
      yield
    ensure
      Imports::Decider.singleton_class.remove_method(:new)
    end

    # klass.new raises SystemStackError inside the block, like a parser recursing on a hostile file.
    def with_stack_overflow_in(klass)
      klass.define_singleton_method(:new) { |*| raise SystemStackError, "stack level too deep" }
      yield
    ensure
      klass.singleton_class.remove_method(:new)
    end
end
