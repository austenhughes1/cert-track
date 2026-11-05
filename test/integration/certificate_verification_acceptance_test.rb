require "test_helper"
require "support/import_samples"
require_relative "../services/verification/verification_test_support"

# Phase 3b acceptance (docs/PLAN.md, "Phase 3b: Issuers and certificate verification", "Done when"):
# zips of synthetic certificates go through the REAL import pipeline, from the upload form to the
# review queue, then are accepted through the review screen:
#
#   ImportsController#create -> Imports::ExpandJob -> ExtractTextJob (pdftotext / tesseract, then
#   zbarimg for QR codes) -> AiExtractJob (Ai::FakeProvider) -> ProcessExtractionJob (issuer match,
#   Verification::Run with local rules) -> Verification::CheckJob (the issuer's site, faked)
#   -> ImportReviewsController#accept -> Compliance::ProjectReport and Compliance::PacketBuilder
#
# Never omit a certificate unless it is verified fake (owner, Nov 4, 2026): a flag from an automatic
# check, a QR code's details or a lookalike link only marks a certificate for review, and it still
# counts and goes in packets; a person's Not found on its panel makes it confirmed fake.
#
# Only the AI model and the issuers' sites are faked: the AI is always Ai::FakeProvider in tests,
# and Verification::HttpClient gets a fake transport (no test ever reaches a real site). The QR
# codes are the synthetic ones in test/fixtures/files/qr/ (made-up names and ids), added to
# synthetic certificate pages; their tests are skipped when zbarimg (zbar-tools) isn't installed.
class CertificateVerificationAcceptanceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include VerificationTestSupport

  AHA_CODE = "212345678901".freeze # the eCard code in aha_ecards_found.html
  ZBAR_MISSING = "zbarimg (zbar-tools) is not installed, so the QR code parts of Phase 3b can't be tested here".freeze

  setup do
    @manager = users(:manager)
    @tower = projects(:tower_2417) # requires OSHA 30, Flagger and First Aid of everyone
    @today = Date.current
    Ai::FakeProvider.reset!
    seed_issuers
  end

  teardown do
    Ai::FakeProvider.reset!
  end

  test "issuers' sites are asked about printed codes: verified, not found, mismatch, and unavailable means a person checks" do
    # Li's expired first aid card would be current again once his new one is confirmed fake (a
    # confirmed fake ranks last, Certificate): without it, the new card is his only one.
    certificates(:li_first_aid).destroy!
    first_aid_on = @today - 30
    first_aid_expires = first_aid_on >> 24
    zip = ImportSamples.zip(
      "cards/aha.pdf" => text_pdf(holder: "Juan A. Ortiz", name: "Adult First Aid CPR AED", completed: first_aid_on,
        expires: first_aid_expires, issuer: "American Heart Association", code: AHA_CODE),
      "cards/ncprf.pdf" => text_pdf(holder: "Li Chen", name: "Adult First Aid CPR AED", completed: @today - 20,
        issuer: "National CPR Foundation", code: "NCPR-404404", link: "nationalcprfoundation.com/verify/"),
      "cards/nof.pdf" => text_pdf(holder: "Dave Miller", name: "OSHA 30 Hour", completed: @today - 40,
        issuer: "National OSHA Foundation", code: "NOF-5550001"),
      "cards/otiec.pdf" => text_pdf(holder: "Maria Garcia", name: "Flagger Certification", completed: @today - 50,
        issuer: "OTI Education Center", code: "OT-7770001")
    )
    sites = {
      "ecards.heart.org" => response(page("aha_ecards_found").sub("03/2027", first_aid_expires.strftime("%m/%Y"))),
      "nationalcprfoundation.com" => response(page("ncprf_no_results")),
      "www.nationaloshafoundation.com" => response(page("nof_found")), # shows Juan Ortiz, not Dave Miller
      "www.oshacardportal.com" => response("<html><body>Service Unavailable</body></html>", status: 503)
    }

    batch = nil
    transport = with_fake_sites(responder: ->(_method, uri, *) { sites.fetch(uri.host) }) do
      Verification::Config.with(auto_checks: true) { batch = run_pipeline(zip, "codes.zip") }
    end

    # One request per issuer site, sending the code and never the holder's name.
    assert_equal sites.keys.sort, transport.requests.map { |request| request[:host] }.sort
    transport.requests.each do |request|
      assert_equal Verification::Config.user_agent, request[:headers]["User-Agent"]
      assert_no_match(/Ortiz|Chen|Miller|Garcia/i, "#{request[:url]} #{request[:body]}", "only the code is sent")
    end
    assert_equal :post, request_to(transport, "ecards.heart.org")[:method]
    assert_includes request_to(transport, "ecards.heart.org")[:body], "codes=#{AHA_CODE}"
    assert_includes request_to(transport, "www.nationaloshafoundation.com")[:url], "certificate_id=NOF-5550001"

    aha, ncprf, nof, otiec = %w[aha ncprf nof otiec].map { |name| item_named(batch, "cards/#{name}.pdf") }
    assert_equal [ "AHA", "NCPRF", "NOF", "OTIEC" ], [ aha, ncprf, nof, otiec ].map { |item| item.matched_certificate_issuer&.code }
    assert [ aha, ncprf, nof, otiec ].all?(&:issuer_matched?), "matched by the issuer code the model read off the card"
    assert_equal [ "verified", "not_found", "mismatch", "needs_check" ], [ aha, ncprf, nof, otiec ].map(&:authenticity_status)
    assert_equal %w[automatic:aha_ecards automatic:national_cpr_foundation automatic:national_osha_foundation
      automatic:osha_card_portal], [ aha, ncprf, nof, otiec ].map(&:authenticity_method)
    assert_equal({ "holder" => "match", "expires_on" => "match" }, aha.authenticity_details["compared"])
    assert_equal "differs", nof.authenticity_details.dig("compared", "holder")
    assert_equal "http_error", otiec.authenticity_details["unavailable"]
    assert_match "The automatic check with OSHA Card Portal didn't work", otiec.authenticity_note
    [ aha, ncprf, nof, otiec ].each do |item|
      assert item.needs_review?, "#{item.original_filename}: auto-accept is off, so a person reviews it"
      assert_nil item.authenticity_checked_by, "an automatic check has no person"
      assert_no_match(/Ortiz|Chen|Miller|Garcia|NCPR-|NOF-|OT-7|#{AHA_CODE}/, "#{item.authenticity_note} #{item.authenticity_details.to_json}",
        "#{item.original_filename}: notes and details never hold names or codes")
    end
    assert_equal [ "NCPR-404404", "https://nationalcprfoundation.com/verify/" ],
      [ ncprf.proposed_verification_code, ncprf.proposed_verification_url ]
    assert_equal "https://www.oshacardportal.com/portalapp/verify/OT-7770001", otiec.proposed_verification_url,
      "no printed link: the issuer's link template with the code"

    # Accepting carries the issuer, code, link and check to the certificate; nothing is asked again.
    sign_in_as @manager
    certificate = accept(ncprf, crew_members(:li_chen), certificate_types(:first_aid))
    assert_equal [ issuer("NCPRF"), "NCPR-404404", "https://nationalcprfoundation.com/verify/" ],
      [ certificate.certificate_issuer, certificate.verification_code, certificate.verification_url ]
    assert_equal ncprf.reload.authenticity_attributes.except("authenticity_checked_at"),
      certificate.authenticity_attributes.except("authenticity_checked_at")
    assert_in_delta ncprf.authenticity_checked_at, certificate.authenticity_checked_at, 1.second
    assert certificate.authenticity_flagged?
    assert_no_enqueued_jobs only: Verification::CheckJob

    verified = accept(aha, crew_members(:juan_ortiz), certificate_types(:first_aid))
    assert verified.authenticity_verified?
    assert_equal [ issuer("AHA"), AHA_CODE ], [ verified.certificate_issuer, verified.verification_code ]

    # The issuer's site found no such certificate, but no person has checked yet: it is only flagged
    # for review. It counts by its dates on the project, with the Review marker, and goes in the packet.
    li = crew_members(:li_chen)
    assert_flagged_for_review_on_project certificate, "valid"
    get root_path
    assert_select "a#tile_verification_flagged [data-count]", "1"
    assert_select "a#tile_verification_fake [data-count]", "0"
    get crew_member_certificate_path(li, certificate)
    assert_response :success
    assert_select "#authenticity", /Not found by issuer/
    assert_select "#authenticity_flagged_hint", text: "Flagged for review. It still counts by its dates and goes in packets " \
      "until someone checks it with the issuer and records the result."
    assert_select "#authenticity_fake_hint", count: 0
    assert_select "#authenticity_form button[data-result=not_found][data-turbo-confirm=?]",
      "Record this certificate as fake? It will count as not valid and be left out of packets.", text: "Not found"

    # A person checks with the issuer and records Not found on its panel: now it is confirmed fake,
    # a gap that counts as not valid, and it is left out of the packet.
    patch crew_member_certificate_authenticity_path(li, certificate),
      params: { authenticity: { status: "not_found", note: "Called the issuer: no such certificate." } }
    assert_redirected_to crew_member_certificate_path(li, certificate, anchor: "authenticity")
    assert_equal [ "not_found", "person", @manager ],
      [ certificate.reload.authenticity_status, certificate.authenticity_method, certificate.authenticity_checked_by ]
    assert certificate.authenticity_confirmed_fake?
    follow_redirect!
    assert_select "#authenticity_fake_hint", text: "Confirmed fake: a person checked it with the issuer. " \
      "It counts as not valid in compliance and is left out of packets."
    assert_select "#authenticity_flagged_hint", count: 0
    assert_fake_on_project certificate, "Confirmed fake: Not found by issuer"
    get root_path
    assert_select "a#tile_verification_fake [data-count]", "1"
    assert_select "a#tile_verification_flagged [data-count]", "0"

    # Automatic checks leave a person's result alone.
    perform_enqueued_jobs(only: Verification::CheckJob) { Verification::CheckJob.perform_later(certificate) }
    assert certificate.reload.authenticity_confirmed_fake?

    # Li hands in his genuine card, completed before the fake one's date: it is current at once,
    # counts, and goes in the packet; the fake one is kept as history.
    post crew_member_certificates_path(li), params: { certificate: { certificate_type_id: certificate_types(:first_aid).id,
      completed_on: (@today - 60).iso8601, expires_on: "", certificate_number: "FA-REAL-1",
      files: [ "", direct_upload(file_fixture("certificate.png").binread, "genuine.png") ] } }
    genuine = li.certificates.find_by!(certificate_number: "FA-REAL-1")
    assert genuine.current?
    assert certificate.reload.superseded?
    cell = Compliance::ProjectReport.new(@tower).row_for(li).cell_for(certificate_types(:first_aid))
    assert_equal [ "valid", genuine ], [ cell.status, cell.certificate ]
    with_packet do |names, _index|
      assert(names.any? { |name| name.start_with?(entry_stem(genuine)) }, "the genuine card is in the packet: #{names.inspect}")
    end
  end

  test "QR codes are read, go to the right page's certificate, and name the issuer by domain; a lookalike is suspicious" do
    skip ZBAR_MISSING unless Certificates::QrReader.available?

    completed = @today - 25
    zip = ImportSamples.zip(
      # The printed issuer names no issuer on the list: only the QR code's domain can match it.
      "photos/redcross.png" => qr_card("redcross_qr.png", holder: "Juan A. Ortiz", name: "Adult First Aid CPR AED",
        completed: completed, issuer: "Summit First Aid Services"),
      "photos/lookalike.png" => qr_card("lookalike_qr.png", holder: "Maria Garcia", name: "Adult First Aid CPR AED",
        completed: completed, issuer: "American Red Cross"),
      # The QR link says Juan A. Ortiz; the card is printed for someone else.
      "photos/360training.png" => qr_card("360training_qr.png", holder: "Juan A. Ortega", name: "OSHA 30 Hour",
        completed: Date.new(2025, 3, 14), issuer: "360training"),
      "photos/unrelated.png" => qr_card("unrelated_qr.png", holder: "Dave Miller", name: "Flagger Certification",
        completed: completed, issuer: "Example Safety Training LLC"),
      "scans/two cards.pdf" => two_certificate_pdf(completed)
    )

    batch = run_pipeline(zip, "qr.zip")

    redcross, lookalike, training, unrelated = %w[photos/redcross.png photos/lookalike.png photos/360training.png
      photos/unrelated.png].map { |name| item_named(batch, name) }
    first_page, second_page = batch.import_items.where(original_filename: "qr.zip/scans/two cards.pdf").order(:page_range).to_a

    # Each item holds the QR codes on its own pages, numbered in its own file.
    assert_equal [ qr("https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123") ], redcross.barcodes
    assert_equal [ qr("https://redcross-verify.com/certificate?certnumber=TEST123") ], lookalike.barcodes
    assert_equal "verify.360training.com", URI(training.barcodes.sole["text"]).host
    assert_equal [ qr("https://example.com/brochure") ], unrelated.barcodes
    assert_equal [ [ "1", [] ], [ "2", [ qr("https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123") ] ] ],
      [ first_page, second_page ].map { |item| [ item.page_range, item.barcodes ] }

    # Matched by the QR code's domain, whatever the card printed; the code and link come from the QR code.
    assert_nil redcross.extraction.dig("certificates", 0, "certificate_issuer_code"), "the model found no issuer code"
    [ redcross, second_page ].each do |item|
      assert_equal [ "REDCROSS", "matched", "TEST123", "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123" ],
        [ item.matched_certificate_issuer&.code, item.issuer_match, item.proposed_verification_code, item.proposed_verification_url ],
        item.original_filename
      assert item.authenticity_needs_check?, "#{item.original_filename}: Red Cross is checked by a person"
    end
    assert_equal [ "360TRAINING", "matched", "12345678" ],
      [ training.matched_certificate_issuer.code, training.issuer_match, training.proposed_verification_code ]
    assert_nil first_page.matched_certificate_issuer
    assert first_page.authenticity_cannot_verify?, "page 1 has nothing to check with"

    # A QR code to a site that imitates an issuer's is suspicious.
    assert lookalike.authenticity_suspicious?
    assert lookalike.authenticity_flagged?
    assert_equal "qr_link", lookalike.authenticity_method
    assert_equal({ "qr_host" => "redcross-verify.com", "looks_like" => "redcross.org" }, lookalike.authenticity_details)
    assert_nil lookalike.proposed_verification_url, "a lookalike link is never offered as the verification link"

    # 360training's QR link carries the holder: a different last name is a mismatch, found locally.
    assert training.authenticity_mismatch?
    assert_equal "qr_details:qr_details_360training", training.authenticity_method

    # A QR code to an unrelated site is noted and otherwise ignored.
    assert unrelated.authenticity_cannot_verify?
    assert_match "A QR code points to example.com, which isn't an issuer's site, so it was ignored.", unrelated.authenticity_note
    assert_equal [ "example.com" ], unrelated.authenticity_details["other_qr_hosts"]

    [ redcross, lookalike, training, unrelated, first_page, second_page ].each do |item|
      assert item.needs_review?, item.original_filename
      assert_no_match(/Ortiz|Ortega|Garcia|Miller|Chen|TEST123|12345678/, "#{item.authenticity_note} #{item.authenticity_details.to_json}",
        "#{item.original_filename}: notes and details never hold names or codes")
    end

    # Accepting carries the issuer, code, link and check found from the QR code to the certificate.
    sign_in_as @manager
    accepted = accept(redcross, crew_members(:juan_ortiz), certificate_types(:first_aid))
    assert_equal [ issuer("REDCROSS"), "TEST123", "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123", "needs_check" ],
      [ accepted.certificate_issuer, accepted.verification_code, accepted.verification_url, accepted.authenticity_status ]

    # The review screen shows the check, and a person may still accept the suspicious card: it
    # stays flagged for review, so it counts by its dates, with the Review marker, and goes in the packet.
    get import_review_path(lookalike)
    assert_response :success
    assert_select "#authenticity", /Suspicious link/
    assert_select "#authenticity_flagged_hint", /\AFlagged for review\. Once accepted, it counts by its dates/
    certificate = accept(lookalike, crew_members(:maria_garcia), certificate_types(:first_aid))
    assert certificate.authenticity_suspicious?
    assert_equal [ issuer("REDCROSS"), "qr_link" ], [ certificate.certificate_issuer, certificate.authenticity_method ]
    assert_flagged_for_review_on_project certificate, "valid"
  end

  test "a QR code on a certificate entered by hand gives it its link and issuer, then it is checked" do
    skip ZBAR_MISSING unless Certificates::QrReader.available?
    sign_in_as @manager
    juan = crew_members(:juan_ortiz)

    post crew_member_certificates_path(juan), params: { certificate: {
      certificate_type_id: certificate_types(:first_aid).id, completed_on: (@today - 10).iso8601, expires_on: "",
      certificate_issuer_id: "", other_issuer_name: "", verification_code: "", verification_url: "",
      files: [ "", direct_upload(qr_card("lookalike_qr.png", holder: "Juan A. Ortiz", name: "Adult First Aid CPR AED",
        completed: @today - 10, issuer: "American Red Cross"), "card.png") ]
    } }
    certificate = juan.certificates.order(:id).last
    assert_redirected_to crew_member_certificate_path(juan, certificate)

    perform_enqueued_jobs(only: [ Certificates::ReadQrCodesJob, Verification::CheckJob ]) do
      perform_enqueued_jobs(only: [ Certificates::ReadQrCodesJob, Verification::CheckJob ])
    end

    certificate.reload
    assert_nil certificate.verification_url, "a lookalike link is not taken as the verification link"
    assert certificate.authenticity_suspicious?
    assert certificate.authenticity_flagged_for_review?
    assert_equal "valid", certificate.compliance_status, "flagged for review: it still counts by its dates"
  end

  private
    # A synthetic certificate page in the format Ai::FakeProvider reads, with the optional
    # Phase 3b lines. Each card gets its own certificate number.
    def card_text(holder:, name:, completed:, issuer:, expires: nil, code: nil, link: nil)
      @card_count = @card_count.to_i + 1
      [
        ImportSamples.certificate_text(holder:, name:, completed: completed.iso8601, expires: expires&.iso8601, issuer:,
          number: "C-#{1000 + @card_count}"),
        ("Verification code: #{code}" if code), ("Verify at: #{link}" if link)
      ].compact.join("\n")
    end

    def text_pdf(**fields)
      ImportSamples.pdf(card_text(**fields))
    end

    # A photo: the certificate text, with a QR fixture (which also prints a made-up name) below it.
    def qr_card(qr_fixture, **fields)
      text = Vips::Image.new_from_buffer(ImportSamples.image(card_text(**fields), format: :png), "")
      text.join(Vips::Image.new_from_file(file_fixture("qr/#{qr_fixture}").to_s), :vertical, expand: true, background: [ 255 ])
        .write_to_buffer(".png")
    end

    # Two certificates in one PDF with a text layer: Li Chen's flagger card, then Juan's first aid
    # card with the Red Cross QR code drawn on page 2 (a scanned image under the text).
    def two_certificate_pdf(completed)
      dpi = ScannedPdf::DPI
      canvas = (Vips::Image.black(8.5 * dpi, 11 * dpi) + 255).cast(:uchar)
        .insert(Vips::Image.new_from_file(file_fixture("qr/redcross_qr.png").to_s), dpi, 5 * dpi)
      page = CombinePDF.parse(ScannedPdf.image_pdf([ [ canvas, ScannedPdf.jpeg_bytes(canvas.copy(interpretation: :b_w)) ] ], dpi:)).pages.first
      page << CombinePDF.parse(text_pdf(holder: "Juan A. Ortiz", name: "Adult First Aid CPR AED", completed:,
        issuer: "Summit First Aid Services")).pages.first

      document = CombinePDF.parse(text_pdf(holder: "Li Chen", name: "Flagger Certification", completed:, issuer: "Example Safety Training LLC"))
      document << page
      document.to_pdf.b
    end

    # Uploads through the real form and runs every job due now, the way Solid Queue would.
    def run_pipeline(zip_bytes, filename)
      sign_in_as @manager
      blob = ImportSamples.blob(zip_bytes, filename: filename)
      post imports_path, params: { import: { uploads: [ "", blob.signed_id ] } }
      batch = ImportBatch.order(:id).last
      assert_redirected_to import_path(batch)

      Current.reset
      perform_enqueued_jobs(at: Time.current) { perform_enqueued_jobs(at: Time.current) }
      assert_empty batch.import_items.in_pipeline, "every file was read"
      assert_empty batch.import_items.failed.pluck(:original_filename, :error_message)
      batch.reload
    end

    def item_named(batch, name)
      batch.import_items.find_by!(original_filename: "#{batch.import_items.first.original_filename.split("/").first}/#{name}")
    end

    def request_to(transport, host)
      transport.requests.find { |request| request[:host] == host } or flunk "no request to #{host}"
    end

    # Accepts through the review screen with the proposed issuer, code and link.
    def accept(item, crew_member, type)
      item.reload
      post accept_import_review_path(item), params: { review: {
        crew_member_id: crew_member.id, certificate_type_id: type.id, completed_on: item.proposed_completed_on.iso8601,
        expires_on: (item.proposed_expires_on.iso8601 if item.proposed_expiry_printed?).to_s,
        certificate_number: item.proposed_certificate_number, issued_by: item.issuer_raw,
        certificate_issuer_id: item.matched_certificate_issuer_id, other_issuer_name: "",
        verification_code: item.proposed_verification_code, verification_url: item.proposed_verification_url
      } }
      assert_response :see_other
      assert item.reload.accepted?, "#{item.original_filename}: #{flash[:alert]}"
      item.certificate.tap { |certificate| assert certificate.current?, "#{item.original_filename}: the newest of its type" }
    end

    # Flagged only for review: the certificate's cell on the tower project keeps the status its
    # dates give it (no gap), the matrix adds the Review marker, and the packet carries its files
    # with nothing about the flag in index.pdf.
    def assert_flagged_for_review_on_project(certificate, status)
      member, type = certificate.crew_member, certificate.certificate_type
      report = Compliance::ProjectReport.new(@tower)
      cell = report.row_for(member).cell_for(type)
      assert_equal [ status, certificate ], [ cell.status, cell.certificate ]
      assert_not_includes report.gaps.map(&:certificate), certificate
      assert_equal 0, report.summary.fetch("fake")

      get project_compliance_path(@tower)
      assert_select "##{dom_id(member, :compliance_row)} td[data-type=#{type.code}][data-status=#{status}]" do
        assert_select "[data-authenticity-review=#{certificate.authenticity_status}][title=?]",
          "Flagged for review: #{certificate.authenticity_label}. It still counts until someone checks it with the issuer.", text: /Review/
      end

      with_packet do |names, index|
        assert(names.any? { |name| name.start_with?(entry_stem(certificate)) }, "its files are in the zip: #{names.inspect}")
        assert_not(index.any? { |line| line.start_with?("Left out of this packet") }, "nothing is left out")
        assert_no_match(/fake|flagged|review|failed verification/i, index.join(" "), "index.pdf says nothing about the flag")
      end
    end

    # Confirmed fake: the certificate's cell on the tower project is "fake" (a gap), the matrix says
    # "Confirmed fake", and the packet leaves its files out and lists it in index.pdf.
    def assert_fake_on_project(certificate, title)
      member, type = certificate.crew_member, certificate.certificate_type
      report = Compliance::ProjectReport.new(@tower)
      cell = report.row_for(member).cell_for(type)
      assert_equal [ "fake", certificate ], [ cell.status, cell.certificate ]
      assert_includes report.gaps.map(&:certificate), certificate
      assert_operator report.summary.fetch("fake"), :>=, 1

      get project_compliance_path(@tower)
      assert_select "##{dom_id(member, :compliance_row)} td[data-type=#{type.code}][data-status=fake]" do
        assert_select "span[title=?]", title, text: "Confirmed fake"
        assert_select "[data-authenticity-review]", count: 0
      end

      builder = Compliance::PacketBuilder.new(@tower)
      assert_includes builder.excluded_cells.map { |_, excluded| excluded.certificate }, certificate
      with_packet do |names, index|
        assert_operator names.size, :>, 1, "the other certificates are in the packet"
        assert_not(names.any? { |name| name.start_with?(entry_stem(certificate)) }, "its files stay out of the zip: #{names.inspect}")
        assert(index.any? { |line| line.start_with?("Left out of this packet") }, "index.pdf lists it as left out")
        assert_includes index, "Failed verification with the issuer"
        assert_no_match(/fake|flagged|review/i, index.join(" "), "the client's index says neither fake nor flagged")
      end
    end

    # The tower project's packet: yields the zip's entry names and index.pdf's lines of text.
    def with_packet
      Dir.mktmpdir do |dir|
        Zip::File.open(Compliance::PacketBuilder.new(@tower).write_zip(File.join(dir, "packet.zip"))) do |zip|
          yield zip.entries.map(&:name), zip.read("index.pdf").scan(/<([0-9a-fA-F]+)> Tj/).map { |(hex)| [ hex ].pack("H*") }
        end
      end
    end

    def entry_stem(certificate)
      member = certificate.crew_member
      "#{member.last_name}_#{member.first_name} - #{certificate.certificate_type.code}"
    end

    def direct_upload(data, filename)
      blob = ActiveStorage::Blob.create_before_direct_upload!(filename: filename, byte_size: data.bytesize,
        checksum: OpenSSL::Digest::MD5.base64digest(data), content_type: "image/png")
      blob.service.upload(blob.key, StringIO.new(data))
      blob.signed_id
    end
end
