require "test_helper"
require "support/import_acceptance_zip"

# Phase 3 acceptance (docs/PLAN.md, "Phase 3: Bulk import", "Done when"): one synthetic zip of
# about 20 samples goes through the REAL pipeline, from the upload form to the summary email:
#
#   ImportsController#create -> Imports::ExpandJob -> ExtractTextJob (pdftotext / tesseract)
#   -> AiExtractJob (Ai::FakeProvider) -> ProcessExtractionJob -> ImportBatch#check_completion!
#   -> ImportMailer#summary
#
# Nothing is stubbed except the AI model (AI_PROVIDER is always fake in tests). The samples and
# the expected outcome of each are in test/support/import_acceptance_zip.rb.
class ImportPipelineAcceptanceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @uploader = users(:manager)
    Ai::FakeProvider.reset!
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    Ai::FakeProvider.reset!
  end

  test "auto-accept off: every file is accounted for, nothing is accepted, one summary email, then the queue empties" do
    zip = ImportAcceptanceZip.build
    assert_not Imports::Config.auto_accept_enabled?, "AUTO_ACCEPT_ENABLED should default to off"

    batch = assert_no_difference -> { Certificate.count } do
      run_pipeline(zip)
    end

    assert_every_file_accounted_for(batch, zip)
    assert_intake_outcomes(batch, zip)
    assert_certificate_items(batch, zip, auto_accept: false)

    assert batch.needs_review?
    assert_equal 0, batch.import_items.accepted.count
    assert_summary_email(batch, accepted: 0, needs_review: 17, duplicates: 1, rejected: 2, failed: 0)

    # The batch page and the review queue render the pipeline's real output.
    get import_path(batch)
    assert_response :success
    assert_select "#count_needs_review [data-count]", "17"
    assert_select "#count_duplicate [data-count]", "1"
    assert_select "#count_rejected [data-count]", "2"
    get import_reviews_path
    assert_response :success

    # Reviewing every item finishes the batch, with no second email.
    review_everything(batch, zip)

    batch.reload
    assert batch.completed?, "the batch should complete once the last item is reviewed (#{batch.status_counts})"
    assert_equal 11, batch.accepted_count
    assert_equal 0, batch.review_count
    assert_equal 1, ActionMailer::Base.deliveries.size, "the summary is sent once per batch"
    assert_includes crew_members(:li_chen).reload.name_aliases, "Li Chenn", "accepting a suggestion learns the spelling"
  end

  test "auto-accept on: only items meeting every rule become certificates, with their files" do
    zip = ImportAcceptanceZip.build

    batch = Imports::Config.with(auto_accept_enabled: true) do
      assert_difference -> { Certificate.count }, zip.auto_accepted.size do
        run_pipeline(zip)
      end
    end

    assert_every_file_accounted_for(batch, zip)
    assert_intake_outcomes(batch, zip)
    assert_certificate_items(batch, zip, auto_accept: true)

    assert_equal 14, zip.auto_accepted.size
    zip.auto_accepted.each do |expected|
      item = item_for(batch, expected)
      certificate = item.certificate
      assert certificate, "#{expected.file} p#{expected.page_range} should be auto-accepted (#{expected.why})"
      assert certificate.source_import?
      assert_equal item.id, certificate.import_item_id
      assert_equal [ item.matched_crew_member, item.matched_certificate_type ], [ certificate.crew_member, certificate.certificate_type ], expected.file
      assert_equal crew_members(expected.crew_member), certificate.crew_member, expected.file if expected.crew_member
      assert_equal certificate_types(expected.type), certificate.certificate_type, expected.file if expected.type
      assert_equal item.proposed_completed_on, certificate.completed_on
      assert_equal expected.expiry.to_s, certificate.expires_on_source, "#{expected.file}: expiry source"
      assert_nil certificate.verified_by, "auto-accepted certificates are not verified by anyone"
      assert_nil item.reviewed_by
      assert_not_nil item.reviewed_at
      group = Certificate.where(crew_member: certificate.crew_member, certificate_type: certificate.certificate_type)
      assert_equal [ group.order(*Certificate.currency_order).first ], group.current.to_a,
        "#{expected.file}: the newest certificate of its type is current (an older card on import goes into history)"
      assert_not item.file.attached?, "#{expected.file}: the certificate holds the file, not the item"
      assert_equal [ certificate ], ActiveStorage::Attachment.where(blob_id: certificate.files.sole.blob_id).map(&:record),
        "#{expected.file}: one link to the file"
    end

    # Page 1 of the packet becomes a certificate holding only that page.
    packet_cert = item_for(batch, zip.certificate(zip.packet, "1")).certificate
    assert_equal "crew_packet p1.pdf", packet_cert.files.sole.filename.to_s
    assert_equal 1, CombinePDF.parse(packet_cert.files.sole.download).pages.size

    zip.needs_review_with_auto_accept.each do |expected|
      item = item_for(batch, expected)
      assert item.needs_review?, "#{expected.file} p#{expected.page_range} should wait for review (#{expected.why})"
      assert_nil item.certificate
    end
    future = item_for(batch, zip.certificate("#{ImportAcceptanceZip::UPLOAD}/certs/ortiz_flagger_future.pdf"))
    assert_match(/completion date .* is in the future/, future.error_message)

    assert batch.needs_review?
    assert_summary_email(batch, accepted: 14, needs_review: 3, duplicates: 1, rejected: 2, failed: 0)
  end

  test "a quota error mid-batch parks the rest until 00:05 UTC; after the reset they finish" do
    denver_noon = Time.find_zone("America/Denver").local(Date.current.year, Date.current.month, Date.current.day, 12)
    travel_to denver_noon
    reset = (denver_noon.utc.to_date + 1).in_time_zone("UTC").change(hour: 0, min: 5)
    assert_equal reset, Ai::Budget.next_reset_at

    batch = upload(ImportAcceptanceZip.small, filename: "small.zip")

    # The first item's AI call goes through; the second one is told the daily allocation is used up.
    armed = false
    arm = lambda do |*, payload|
      next if armed || !payload[:job].is_a?(Imports::AiExtractJob)

      armed = true
      Ai::FakeProvider.fail_next!
    end
    ActiveSupport::Notifications.subscribed(arm, "perform.active_job") { run_jobs }

    first, *parked = batch.import_items.order(:id).to_a
    assert first.needs_review?, "the item read before the quota error is processed"
    assert_equal 2, parked.size
    parked.each do |item|
      assert item.extracting?, "#{item.original_filename} should still be in the pipeline"
      assert_equal reset, item.next_attempt_at, "parked until the next 00:05 UTC"
      assert item.extracted_text.present?, "text extraction is free, so it already ran"
      assert_nil item.extraction
    end
    assert_equal 2, Ai::FakeProvider.calls.size, "after the quota error no further AI call is made today"
    assert Ai::Budget.exhausted?

    parked_jobs = enqueued_jobs.select { |job| job[:job] == Imports::AiExtractJob }
    assert_equal parked.map(&:to_global_id).map(&:to_s), parked_jobs.map { |job| job[:args].first["_aj_globalid"] }
    parked_jobs.each { |job| assert_in_delta reset.to_f, job[:at], 1 }

    batch.reload
    assert batch.processing?
    assert_equal 2, batch.progress[:waiting_for_budget]
    assert_nil batch.summary_sent_at
    assert_empty ActionMailer::Base.deliveries

    get import_path(batch)
    assert_select "#count_waiting_for_budget [data-count]", "2"
    assert_select "#batch_status_text", /continue after 00:05 UTC/
    get imports_path
    assert_select "#ai_waiting", /2 items waiting for the 00:05 UTC reset/

    # Just before the reset nothing runs yet.
    travel_to reset - 1.minute
    run_jobs
    assert parked.each(&:reload).all?(&:extracting?)

    travel_to reset + 1.minute
    assert_not Ai::Budget.exhausted?
    run_jobs

    parked.each(&:reload)
    assert parked.all?(&:needs_review?), parked.map { |item| [ item.status, item.error_message ] }.inspect
    assert parked.all? { |item| item.next_attempt_at.nil? }
    assert_equal 4, Ai::FakeProvider.calls.size
    assert_empty enqueued_jobs.select { |job| job[:job] == Imports::AiExtractJob }

    batch.reload
    assert batch.needs_review?
    assert_equal 0, batch.progress[:waiting_for_budget]
    assert_summary_email(batch, accepted: 0, needs_review: 3, duplicates: 0, rejected: 0, failed: 0)
  end

  # Phase 3b (docs/PLAN.md, step 6b): the QR code is read locally (zbarimg) from the uploaded PDF,
  # and the split gives it to the certificate on its page, which then matches its issuer by domain.
  test "Phase 3b: a QR code on page 2 of a two-certificate PDF goes to page 2's certificate and names its issuer" do
    skip "zbarimg (zbar-tools) is not installed" unless Certificates::QrReader.available?
    CertificateIssuer.seed_defaults!
    qr_page = CombinePDF.parse(file_fixture("qr/two_pages_qr_on_2.pdf").binread).pages.fetch(1) # Juan A. Ortiz, Red Cross QR
    pdf = CombinePDF.parse(ImportSamples.pdf({ holder: "Li Chen", name: "Flagger Certification" }))
    pdf << qr_page
    entry = ->(page, holder, code, issuer) {
      { "pages" => [ page ], "holder_name" => holder, "certificate_type_code" => code, "certificate_name_as_printed" => nil,
        "issuer" => issuer, "certificate_issuer_code" => nil, "certificate_number" => nil, "verification_code" => nil,
        "verification_url" => nil, "completed_on" => "2025-03-14", "expires_on" => nil, "confidence" => 0.9, "notes" => nil }
    }
    # Page 2 has too little text for OCR, so it goes to the vision model in a call of its own.
    Ai::FakeProvider.reply_next!({ "certificates" => [ entry.(1, "Li Chen", "FLAGGER", "Example Safety Training LLC") ], "non_certificate_pages" => [] })
    Ai::FakeProvider.reply_next!({ "certificates" => [ entry.(2, "Juan A. Ortiz", "FIRSTAID", "American Red Cross") ], "non_certificate_pages" => [] })

    batch = upload(pdf.to_pdf.b, filename: "two cards.pdf")
    run_jobs

    first, second = batch.reload.import_items.order(:id).to_a
    assert_equal [ "1", "2" ], [ first.page_range, second.page_range ]
    assert_equal [ [], [ { "page" => 1, "text" => "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123" } ] ],
      [ first.barcodes, second.barcodes ]
    assert_equal [ "Example Safety Training LLC", "matched" ], [ first.matched_certificate_issuer.name, first.issuer_match ], "added from the card"
    assert_equal [ "REDCROSS", "matched", "TEST123", "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123" ],
      [ second.matched_certificate_issuer.code, second.issuer_match, second.proposed_verification_code, second.proposed_verification_url ]
    assert second.authenticity_needs_check?, "Red Cross is checked by a person"
    assert_not first.authenticity_flagged?
  end

  private
    # Uploads through the real form, then runs every job the way Solid Queue would (no
    # signed-in user). Returns the batch.
    def run_pipeline(zip)
      temp_dirs = certtrack_temp_dirs
      batch = upload(zip.bytes)
      run_jobs
      assert_empty certtrack_temp_dirs - temp_dirs, "the pipeline's temp folders should be cleaned up"
      assert_stored_once(batch.reload)
      batch
    end

    # The zip is deleted once unpacked, and every file left is stored once: held by the item
    # still waiting for review, or by the certificate it became, never both, and nothing
    # unattached (such as the whole packet PDF once its pages were cut out).
    def assert_stored_once(batch)
      assert_not batch.uploads.attached?, "the zip is deleted once unpacked"
      assert_empty ActiveStorage::Blob.unattached.pluck(:filename), "files nothing holds should be purged"
      shared = ActiveStorage::Attachment.group(:blob_id).having("count(DISTINCT record_type) > 1").count
      assert_empty shared, "a file held by both an import item and a certificate"
    end

    # The item's file as stored (a blob): an accepted item's is its certificate's.
    def stored_file(item)
      item.accepted? ? item.certificate.files.sole.blob : item.file.blob
    end

    def upload(bytes, filename: ImportAcceptanceZip::UPLOAD)
      sign_in_as @uploader
      blob = ImportSamples.blob(bytes, filename: filename) # as a finished direct upload leaves it
      assert_difference -> { ImportBatch.count } do
        post imports_path, params: { import: { uploads: [ "", blob.signed_id ] } }
      end
      batch = ImportBatch.order(:id).last
      assert_redirected_to import_path(batch)
      assert batch.receiving?
      assert_equal @uploader, batch.uploaded_by
      assert_enqueued_with job: Imports::ExpandJob, args: [ batch ]
      batch
    end

    # Performs everything due now, and every job those enqueue that is also due now. Jobs
    # scheduled for later (an item parked until the AI allocation resets) stay queued.
    def run_jobs
      Current.reset
      perform_enqueued_jobs(at: Time.current) { perform_enqueued_jobs(at: Time.current) }
    end

    # This process's temp folders and files (their names hold the pid; parallel workers share /tmp).
    def certtrack_temp_dirs
      Dir.glob(File.join(Dir.tmpdir, "certtrack-*-#{Process.pid}-*"))
    end

    def item_for(batch, expected)
      batch.import_items.find_by(original_filename: expected.file, page_range: expected.page_range, status: %i[needs_review accepted]) or
        flunk "no item for #{expected.file} page #{expected.page_range.inspect}: " \
              "#{batch.import_items.where(original_filename: expected.file).pluck(:page_range, :status).inspect}"
    end

    # Every file in the zip maps to items in a finished state; the counts add up.
    def assert_every_file_accounted_for(batch, zip)
      intake = batch.import_items.where(source_item_id: nil).order(:id).to_a
      assert_equal zip.candidates.sort, intake.map(&:original_filename).sort, "one intake item per file in the zip"
      assert_equal zip.candidates.size, batch.files_count
      assert_equal 18, batch.files_count

      zip.junk.each do |name|
        assert_not batch.import_items.exists?([ "original_filename LIKE ?", "%#{File.basename(name)}" ]),
          "#{name} is junk and should be skipped silently"
      end
      assert_not batch.import_items.exists?(original_filename: "#{ImportAcceptanceZip::UPLOAD}/nested/level1.zip"),
        "an opened nested zip is not itself an item"

      items = batch.import_items.to_a
      assert items.all? { |item| item.terminal? || item.needs_review? },
        "every item ends terminal or needs review: #{items.reject(&:terminal?).reject(&:needs_review?).map { |item| [ item.original_filename, item.status, item.error_message ] }}"
      assert_equal 0, batch.status_counts.values_at("pending", "extracting", "failed").sum,
        batch.import_items.failed.pluck(:original_filename, :error_message).inspect
      assert_equal zip.candidates.size + 2, items.size, "the packet's 3 certificates are 3 items"
      assert_equal items.size, batch.items_count
      assert_equal items.size, batch.status_counts.values.sum
      assert_nil batch.error_message
    end

    # Duplicate, rejections, zip-slip, the multi-certificate split and the AI calls.
    def assert_intake_outcomes(batch, zip)
      copy_name, original_name = zip.duplicate
      copy = batch.import_items.find_by!(original_filename: copy_name)
      original = batch.import_items.find_by!(original_filename: original_name, source_item_id: nil)
      assert copy.duplicate?, "the exact copy is flagged as a duplicate"
      assert_equal original, copy.duplicate_of
      assert_equal original.sha256, copy.sha256
      assert_not copy.file.attached?
      assert_nil copy.extracted_text, "a duplicate gets no text extraction"
      assert_nil copy.extraction, "a duplicate gets no AI work"

      zip.rejected.each do |name, reason|
        item = batch.import_items.find_by!(original_filename: name)
        assert item.rejected?, "#{name} should be rejected"
        assert_match reason, item.rejection_reason, name
      end
      outline = batch.import_items.find_by!(original_filename: "#{ImportAcceptanceZip::UPLOAD}/certs/course_outline.pdf")
      assert_equal [ 1 ], outline.extraction["non_certificate_pages"]
      assert outline.needs_review?, "no certificate found: a person confirms it, nothing is rejected unseen"
      assert_equal Imports::ProcessExtractionJob::NO_CERTIFICATE, outline.error_message

      evil = batch.import_items.find_by!(original_filename: "#{ImportAcceptanceZip::UPLOAD}/../../#{zip.evil_name}")
      assert_nil evil.sha256
      assert_not evil.file.attached?
      assert_nothing_written_outside_temp(zip.evil_name)
      assert_empty Ai::FakeProvider.calls.select { |call| call.prompt.include?("Evil Example") }

      source = batch.import_items.find_by!(original_filename: zip.packet, source_item_id: nil)
      family = [ source, *source.split_items.order(:id) ]
      assert_equal %w[1 3 4], family.map(&:page_range), "the course outline on page 2 belongs to no certificate"
      assert_equal [ 2 ], source.extraction["non_certificate_pages"]
      assert_equal [ "crew_packet p1.pdf", "crew_packet p3.pdf", "crew_packet p4.pdf" ], family.map { |item| stored_file(item).filename.to_s }
      assert family.all? { |item| item.sha256 == source.sha256 && item.original_filename == zip.packet }
      family.zip([ "Li Chen", "David Millar", "Sam Price" ]).each do |item, holder|
        file = stored_file(item)
        assert_equal 1, CombinePDF.parse(file.download).pages.size, "#{file.filename} holds one page"
        file.open do |local|
          assert_includes Imports::TextExtractor.new(local.path, content_type: "application/pdf").call.text, "Awarded to: #{holder}"
        end
        assert_includes item.extracted_text, holder
        (family.map(&:holder_name_raw) - [ holder ]).each { |other| assert_not_includes item.extracted_text, other }
      end

      # One call per file that reached the AI step: text PDFs to the text model, scans and photos to the
      # vision model. The duplicate, notes.txt and the zip-slip entry cost nothing.
      ai_files = zip.candidates.size - 3
      assert_equal ai_files, Ai::FakeProvider.calls.size
      assert_equal [ Ai::Config::FAKE_MODEL, Ai::Config::FAKE_VISION_MODEL ], Ai::FakeProvider.calls.map(&:model).uniq.sort, "photos and scans go to the vision model"
      assert_equal ai_files, batch.import_items.where.not(extraction: nil).where(source_item_id: nil).count
      assert batch.import_items.where(source_item_id: nil).where.not(extraction: nil).all? { |item| item.ai_units_used.positive? }
      assert_operator Ai::Budget.used_today, :>, 0
    end

    # Each certificate's proposals: OCR'd holder name, person and type matches, confidence.
    def assert_certificate_items(batch, zip, auto_accept:)
      assert_equal 16, zip.certificates.size
      zip.certificates.each do |expected|
        item = item_for(batch, expected)
        label = "#{expected.file} p#{expected.page_range} (#{expected.why})"
        expected_status = auto_accept && expected.auto_accept ? "accepted" : "needs_review"

        assert_equal expected_status, item.status, label
        assert_equal expected.holder, item.holder_name_raw, "#{label}: holder name as read"
        assert_equal expected.person_match == :created ? "matched" : expected.person_match.to_s, item.person_match, "#{label}: person match"
        if expected.person_match == :created
          assert_equal NameNormalizer.normalize(expected.holder), NameNormalizer.normalize(item.matched_crew_member.full_name), "#{label}: added from the card"
        else
          assert_same_record expected.crew_member && crew_members(expected.crew_member), item.matched_crew_member, "#{label}: person"
        end
        assert_equal expected.type_match == :created ? "matched" : expected.type_match.to_s, item.type_match, "#{label}: type match"
        if expected.type_match == :created
          assert_equal item.certificate_name_raw, item.matched_certificate_type.name, "#{label}: type added from the card"
        else
          assert_same_record expected.type && certificate_types(expected.type), item.matched_certificate_type, "#{label}: type"
        end
        assert_equal BigDecimal("0.95"), item.confidence, label
        assert_equal "fake", item.provider
        assert stored_file(item), label
        assert_equal expected.page_range.nil?, stored_file(item).content_type.start_with?("image/"), label
        if expected.ocr
          assert_match(/Awarded to: #{Regexp.escape(expected.holder)}/, item.extracted_text, "#{label}: OCR text")
        end
        assert_equal item.matched_crew_member_id, item.person_suggestions.first["id"], label
      end
    end

    # assert_equal, or assert_nil when nothing should match.
    def assert_same_record(expected, actual, message)
      expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
    end

    def assert_summary_email(batch, accepted:, needs_review:, duplicates:, rejected:, failed:)
      assert_not_nil batch.reload.summary_sent_at
      assert_equal 1, ActionMailer::Base.deliveries.size, "exactly one summary email"
      mail = ActionMailer::Base.deliveries.last
      assert_equal [ @uploader.email_address ], mail.to
      expected_subject = needs_review.positive? ? "CertTrack import: #{needs_review} items need review" : "CertTrack import finished"
      assert_equal expected_subject, mail.subject

      text = mail.text_part.body.to_s
      { "Accepted" => accepted, "Needs review" => needs_review, "Duplicates" => duplicates, "Rejected" => rejected,
        "Failed" => failed }.each do |label, count|
        assert_includes text, "#{"#{label}:".ljust(14)}#{count}"
      end
      assert_includes text, "You uploaded #{batch.files_count} files"
      assert_includes text, "CertTrack found #{batch.items_count} items in them."
      assert_includes text, "This batch: http://example.com/imports/#{batch.id}"
      assert_includes text, "Review queue: http://example.com/imports/review" if needs_review.positive?
    end

    # The zip-slip entry ("../../evil-<hex>.pdf") must not land anywhere "../.." could reach
    # from the temp folders or the app's working directory.
    def assert_nothing_written_outside_temp(evil_name)
      tmp = Pathname(Dir.tmpdir)
      root = Rails.root
      places = [ tmp, tmp.parent, tmp.parent.parent, root, root.parent, root.parent.parent, root.join("tmp"), Pathname(Dir.pwd) ]
      places.uniq.each do |place|
        assert_not place.join(evil_name).exist?, "the zip-slip entry was written to #{place}"
      end
    end

    # Accepts every item with a known, active person and type and sane dates; rejects the rest.
    def review_everything(batch, zip)
      sign_in_as @uploader
      zip.certificates.each do |expected|
        item = item_for(batch, expected)
        get import_review_path(item)
        assert_response :success, "#{expected.file}: review screen"

        member = expected.crew_member && crew_members(expected.crew_member)
        if member&.active? && expected.type && item.error_message.blank?
          post accept_import_review_path(item), params: { review: {
            crew_member_id: member.id, certificate_type_id: certificate_types(expected.type).id,
            completed_on: item.proposed_completed_on.iso8601,
            expires_on: (item.proposed_expires_on.iso8601 if item.proposed_expiry_printed?).to_s,
            certificate_number: item.proposed_certificate_number, issued_by: item.issuer_raw
          } }
          assert_response :see_other, "#{expected.file}: accept"
          assert item.reload.accepted?, "#{expected.file}: #{flash[:alert]}"
          assert_equal @uploader, item.certificate.verified_by
          assert_equal expected.expiry.to_s, item.certificate.expires_on_source, "#{expected.file}: expiry source"
        else
          post reject_import_review_path(item), params: { reject: { reason: "Not one of our crew" } }
          assert_response :see_other, "#{expected.file}: reject"
          assert item.reload.rejected?
        end
      end
      outline = batch.import_items.needs_review.find_by!(original_filename: "#{ImportAcceptanceZip::UPLOAD}/certs/course_outline.pdf")
      get import_review_path(outline)
      assert_response :success, "course outline: review screen"
      post reject_import_review_path(outline), params: { reject: { reason: "Not a certificate" } }
      assert outline.reload.rejected?
      assert_equal 0, ImportItem.review_queue.where(import_batch: batch).count
    end
end
