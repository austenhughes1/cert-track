require "test_helper"
require_relative "verification_test_support"

class Verification::RunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include VerificationTestSupport

  REDCROSS_QR = "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123".freeze
  LOOKALIKE_QR = "https://redcross-verify.com/certificate?certnumber=TEST123".freeze
  UNRELATED_QR = "https://example.com/brochure".freeze
  TRAINING_QR = "https://verify.360training.com/qrcode-certificate-validation?enrollmentId=12345678&s_fname=Juan" \
    "&s_mname=A&s_lname=Ortiz&course=OSHA%2030-Hour%20Construction&issued=03/14/2025".freeze
  AHA_CODE = "212345678901".freeze
  PERSONAL = /juan|ortiz|212345678901|TEST123|12345678|2025|2027/i

  setup do
    seed_issuers
    @batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing)
  end

  def item(issuer_code: nil, issuer_match: (issuer_code ? :matched : :unmatched), **attrs)
    ImportItem.create!({ import_batch: @batch, status: :needs_review, sha256: SecureRandom.hex(32),
      original_filename: "card.jpg", holder_name_raw: "Juan A. Ortiz", proposed_completed_on: Date.new(2025, 3, 14),
      matched_certificate_issuer: (issuer(issuer_code) if issuer_code), issuer_match: issuer_match }.merge(attrs))
  end

  def check(record, **options)
    Verification::Run.new(record, **options).call
  end

  # Runs with automatic checks on and every request answered by replies, in order.
  def check_online(record, *replies, **options)
    result = nil
    transport = with_fake_sites(*replies) { with_auto_checks { result = check(record, **options) } }
    [ result, transport ]
  end

  def assert_recorded(record, status, method)
    record.reload
    assert_equal [ status.to_s, method ], [ record.authenticity_status, record.authenticity_method ]
    assert_not_nil record.authenticity_checked_at
    assert_nil record.authenticity_checked_by
  end

  # Rule 1

  test "a QR code to a lookalike site is suspicious, whatever else the certificate has" do
    record = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE, barcodes: [ qr(LOOKALIKE_QR) ])

    result, transport = check_online(record)

    assert_equal :suspicious, result.status
    assert_equal "The QR code points to redcross-verify.com, which looks like redcross.org but isn't.", result.note
    assert_equal({ "qr_host" => "redcross-verify.com", "looks_like" => "redcross.org" }, result.details)
    assert_recorded record, :suspicious, "qr_link"
    assert record.authenticity_flagged?
    assert_empty transport.requests, "nothing is asked once a QR code is suspicious"
  end

  test "suspicious wins over an issuer with no registry and over QR details" do
    assert_equal :suspicious, check(item(issuer_code: "EMPLOYER", barcodes: [ qr(LOOKALIKE_QR) ])).status
    assert_equal :suspicious, check(item(issuer_code: "360TRAINING", barcodes: [ qr(TRAINING_QR), qr("http://360training-verify.com/x") ])).status
  end

  test "a printed or typed verification link to a lookalike site is suspicious too" do
    record = item(issuer_code: "REDCROSS", proposed_verification_code: "TEST123", proposed_verification_url: LOOKALIKE_QR)

    result = check(record)

    assert_equal :suspicious, result.status
    assert_equal "The verification link points to redcross-verify.com, which looks like redcross.org but isn't.", result.note
    assert_equal({ "link_host" => "redcross-verify.com", "looks_like" => "redcross.org" }, result.details)
    assert_recorded record, :suspicious, "verification_link"

    certificate = certificates(:juan_first_aid)
    certificate.update!(verification_url: "https://www.redcross-verify.com/c/12345")
    assert_equal :suspicious, check(certificate).status
  end

  test "a QR code spelled with look-alike letters is suspicious, as text or as punycode" do
    [ "https://www.red\u0441r\u043Ess.org/take-a-class/qrcode?certnumber=TEST123", # Cyrillic с and о
      "https://www.xn--redcrss-ejg.org/take-a-class/qrcode?certnumber=TEST123",    # punycode for redcrоss.org
      "https://www.xn--redcrss-0ug.org/c/1" ].each do |text|
      record = item(issuer_code: "REDCROSS", barcodes: [ qr(text) ])

      result = check(record)

      assert_equal :suspicious, result.status, text
      assert_equal "The QR code points to a web address spelled with look-alike letters to pass for redcross.org.", result.note
      assert_equal [ "redcross.org", true ], result.details.values_at("looks_like", "lookalike_letters"), text
      assert record.reload.authenticity_flagged?
    end
  end

  test "a disguised QR link, another site's name before an @, is suspicious" do
    record = item(issuer_code: "REDCROSS", barcodes: [ qr("https://www.redcross.org@verify-now.net/c/1") ])

    result = check(record)

    assert_equal :suspicious, result.status
    assert_equal "The QR code is disguised: it opens verify-now.net, not the site its address seems to name.", result.note
    assert_equal({ "qr_host" => "verify-now.net", "disguised" => true }, result.details, "not also listed as an unrelated site")
  end

  test "a QR code with a web address CertTrack can't read is noted and left for a person, never dropped" do
    record = item(issuer_code: "REDCROSS", barcodes: [ qr("https://www.m\u00FCnchen-schulung.de/zertifikat") ])

    result = check(record)

    assert_equal :needs_check, result.status, "something for a person to look at, so not \"can't be verified\""
    assert_equal "Open the verification page to check this certificate with American Red Cross. A QR code holds a web " \
      "address spelled with letters other than a to z (m\u00FCnchen-schulung.de); look at it before trusting it.", result.note
    assert_equal({ "unreadable_qr_hosts" => [ "m\u00FCnchen-schulung.de" ] }, result.details)
  end

  test "a QR code holding one dotted word (a date, an ID, a name) is not named as a site" do
    record = item(issuer_code: "REDCROSS", barcodes: [ qr("2025.03.14"), qr("AB12.3456"), qr("juan.ortiz") ])

    result = check(record)

    assert_equal :cannot_verify, result.status
    assert_equal "There's no verification code, link or QR code to check this certificate with.", result.note
    assert_equal({}, result.details)
  end

  test "a QR code to an unrelated site is noted and otherwise ignored" do
    record = item(issuer_code: "REDCROSS", proposed_verification_url: REDCROSS_QR, barcodes: [ qr(UNRELATED_QR), qr(REDCROSS_QR, page: 2) ])

    result = check(record)

    assert_equal :needs_check, result.status
    assert_equal "Open the verification page to check this certificate with American Red Cross. " \
      "A QR code points to example.com, which isn't an issuer's site, so it was ignored.", result.note
    assert_equal({ "other_qr_hosts" => [ "example.com" ] }, result.details)
    assert_equal result.note, record.reload.authenticity_note
  end

  test "QR codes that aren't links are ignored" do
    result = check(item(issuer_code: "REDCROSS", barcodes: [ qr("WIFI:S:guest;;"), qr("Juan A. Ortiz") ]))

    assert_equal :cannot_verify, result.status
    assert_no_match PERSONAL, result.note
  end

  # Rule 2

  test "360training QR details that match: needs a check, recorded as a QR details check" do
    record = item(issuer_code: "360TRAINING", proposed_verification_url: TRAINING_QR, barcodes: [ qr(TRAINING_QR) ])

    result = check(record)

    assert_equal :needs_check, result.status
    assert_equal "The QR code's details match the certificate; open the link to confirm with 360training.", result.note
    assert_recorded record, :needs_check, "qr_details:qr_details_360training"
    assert_equal({ "compared" => { "holder_last_name" => "match", "completed_on" => "match" } }, record.authenticity_details)
  end

  test "360training QR details with another last name: mismatch" do
    record = item(issuer_code: "360TRAINING", holder_name_raw: "Juan Ortega", barcodes: [ qr(TRAINING_QR) ])

    assert_equal :mismatch, check(record).status
    assert record.reload.authenticity_flagged?
  end

  test "the matched crew member's names count as the holder's too" do
    record = item(issuer_code: "360TRAINING", holder_name_raw: "Jaun Ortis", matched_crew_member: crew_members(:juan_ortiz),
      person_match: :matched, barcodes: [ qr(TRAINING_QR) ])

    assert_equal :needs_check, check(record).status, "the misread name differs, the matched member's doesn't"

    record.update!(person_match: :suggested)
    assert_equal :mismatch, check(record).status, "a suggested member isn't the holder yet"
  end

  test "a crew member picked by hand is the holder: the printed name no longer counts" do
    record = item(issuer_code: "360TRAINING", holder_name_raw: "Juan A. Ortiz", matched_crew_member: crew_members(:maria_garcia),
      person_match: :picked, barcodes: [ qr(TRAINING_QR) ])

    assert_equal :mismatch, check(record).status, "the card is Juan's, but it would become Maria's certificate"
  end

  test "360training with several QR codes on the page: the one naming the holder is compared" do
    marias = TRAINING_QR.sub("enrollmentId=12345678", "enrollmentId=87654321").sub("s_fname=Juan", "s_fname=Maria")
      .sub("s_mname=A", "s_mname=").sub("s_lname=Ortiz", "s_lname=Garcia")
    record = item(issuer_code: "360TRAINING", holder_name_raw: "Maria Garcia", barcodes: [ qr(TRAINING_QR), qr(marias) ])

    assert_equal :needs_check, check(record).status, "Juan's card on the same page is not a mismatch for Maria"

    record.update!(holder_name_raw: "Li Chen")
    assert_equal :mismatch, check(record).status, "no QR code on the page names Li Chen"
  end

  test "360training without a QR code to compare: the other rules decide" do
    assert_equal :cannot_verify, check(item(issuer_code: "360TRAINING")).status, "nothing for a person to check with"

    result = check(item(issuer_code: "360TRAINING", proposed_verification_code: "12345678"))
    assert_equal :needs_check, result.status
    assert_equal "Open the verification page to check this certificate with 360training.", result.note
  end

  # Rule 3

  test "automatic: the issuer's site confirms it, so it is verified" do
    record = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE, proposed_expires_on: Date.new(2027, 3, 31))

    result, transport = check_online(record, response(page("aha_ecards_found")))

    assert_equal :verified, result.status
    assert_recorded record, :verified, "automatic:aha_ecards"
    assert_equal({ "issuer_status" => "Active", "compared" => { "holder" => "match", "expires_on" => "match" } }, record.authenticity_details)
    assert_equal "codes=#{AHA_CODE}", transport.requests.sole[:body]
  end

  test "automatic: not found and mismatch are recorded and flagged" do
    record = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE)
    check_online(record, response(page("aha_ecards_invalid")))
    assert_recorded record, :not_found, "automatic:aha_ecards"
    assert record.authenticity_flagged?

    record = item(issuer_code: "OTIEC", proposed_verification_code: "AB12CD34", holder_name_raw: "Maria Garcia")
    check_online(record, response(page("osha_card_portal_valid")))
    assert_recorded record, :mismatch, "automatic:osha_card_portal"
  end

  test "automatic: an unavailable site is recorded as needs a check, with the note saying why" do
    record = item(issuer_code: "NOF", proposed_verification_code: "NOF-77")

    result, = check_online(record, response(page("nof_critical_error"), status: 500))

    assert_equal :unavailable, result.status, "the result says what happened"
    assert_recorded record, :needs_check, "automatic:national_osha_foundation"
    assert_match "answered with an error (HTTP 500)", record.authenticity_note
    assert_equal({ "unavailable" => "http_error" }, record.authenticity_details)
    assert_no_enqueued_jobs only: Verification::CheckJob
  end

  test "automatic checks are off by default in tests: no request, and a person is asked to check" do
    record = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE)

    result = nil
    transport = with_fake_sites { result = check(record) }

    assert_empty transport.requests
    assert_equal :needs_check, result.status
    assert_equal "Automatic checks are switched off. Open the verification page to check this certificate with " \
      "American Heart Association.", result.note
    assert_recorded record, :needs_check, "rules"
  end

  test "network: false skips the automatic check even when automatic checks are on" do
    transport = with_fake_sites { with_auto_checks { check(item(issuer_code: "AHA", proposed_verification_code: AHA_CODE), network: false) } }

    assert_empty transport.requests
  end

  test "a check held back by network: false is deferred only while automatic checks are on and it could run" do
    deferred = ->(record, auto: true) {
      run = Verification::Run.new(record, network: false)
      with_auto_checks(auto) { run.call }
      run.automatic_check_deferred?
    }

    record = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE)
    assert deferred.(record)
    assert_equal "CertTrack will ask American Heart Association's site to confirm it in a moment. " \
      "Open the verification page to check this certificate with American Heart Association.", record.authenticity_note
    assert_not deferred.(item(issuer_code: "AHA", proposed_verification_code: AHA_CODE), auto: false), "checks off"
    assert_not deferred.(item(issuer_code: "AHA")), "no code"
    assert_match "no verification code", ImportItem.order(:id).last.authenticity_note
    assert_not deferred.(item(issuer_code: "AHA", issuer_match: :suggested, proposed_verification_code: AHA_CODE)), "suggested issuer"
    assert_not deferred.(item(issuer_code: "REDCROSS", proposed_verification_code: "RC-1")), "assisted issuer"
  end

  test "automatic: without a code, the one in the issuer's link is sent" do
    record = item(issuer_code: "NOF",
      proposed_verification_url: "https://www.nationaloshafoundation.com/certificate-verification/?certificate_id=NOF-88")

    result, transport = check_online(record, response(page("nof_found")))

    assert_equal :verified, result.status
    assert_equal "https://www.nationaloshafoundation.com/certificate-verification/?certificate_id=NOF-88", transport.requests.sole[:url]
  end

  test "automatic: the record's code wins over the link's" do
    record = item(issuer_code: "OTIEC", proposed_verification_code: "TYPED1",
      barcodes: [ qr("https://www.oshacardportal.com/portalapp/verify/QR22") ])

    _, transport = check_online(record, response(page("osha_card_portal_valid")))

    assert_equal "https://www.oshacardportal.com/portalapp/verify/TYPED1", transport.requests.sole[:url]
  end

  test "automatic: a link on another site never gives the code" do
    record = item(issuer_code: "OTIEC", barcodes: [ qr("https://example.com/verify/QR22") ])

    result, transport = check_online(record)

    assert_empty transport.requests
    assert_equal :cannot_verify, result.status
  end

  test "automatic: several of the issuer's QR codes with different codes give no code (another person's card may be on the page)" do
    first = "https://www.nationaloshafoundation.com/certificate-verification/?certificate_id=NOF-1001"
    second = "https://www.nationaloshafoundation.com/certificate-verification/?certificate_id=NOF-2002"

    result, transport = check_online(item(issuer_code: "NOF", barcodes: [ qr(first), qr(second) ]))
    assert_equal :needs_check, result.status
    assert_match "National OSHA Foundation can be checked automatically, but there's no verification code.", result.note
    assert_empty transport.requests

    _result, transport = check_online(item(issuer_code: "NOF", barcodes: [ qr(first), qr(first, page: 2) ]),
      response(page("nof_found")))
    assert_equal "https://www.nationaloshafoundation.com/certificate-verification/?certificate_id=NOF-1001", transport.requests.sole[:url]
  end

  test "an expiry CertTrack computed from the type is never compared with the issuer's" do
    computed = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE, proposed_expires_on: Date.new(2026, 3, 14),
      proposed_expires_on_source: :computed)
    result, = check_online(computed, response(page("aha_ecards_found")))
    assert_equal :verified, result.status, "the site's renewal month (03/2027) isn't compared with a date CertTrack worked out"
    assert_not result.details["compared"].key?("expires_on")

    printed = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE, proposed_expires_on: Date.new(2026, 3, 14),
      proposed_expires_on_source: :printed)
    assert_equal :mismatch, check_online(printed, response(page("aha_ecards_found"))).first.status

    certificate = certificates(:juan_first_aid) # expires_on_source computed
    certificate.update!(certificate_issuer: issuer("AHA"), verification_code: AHA_CODE)
    assert certificate.expiry_computed?
    assert_equal :verified, check_online(certificate, response(page("aha_ecards_found"))).first.status
  end

  test "automatic: without any code, a person checks the link" do
    record = item(issuer_code: "AHA", proposed_verification_url: "https://ecards.heart.org/student/myecards")

    result, transport = check_online(record)

    assert_empty transport.requests
    assert_equal :needs_check, result.status
    assert_match "American Heart Association can be checked automatically, but there's no verification code.", result.note
  end

  test "a fuzzy-name issuer suggestion is not trusted with an automatic check" do
    record = item(issuer_code: "AHA", issuer_match: :suggested, proposed_verification_code: AHA_CODE)

    result, transport = check_online(record)

    assert_empty transport.requests
    assert_equal "Open the verification link, or look the code up on the issuer's own site.", result.note
  end

  test "an automatic check that isn't on the issuer's own site is not run" do
    issuer("NCPRF").update!(automatic_check: "aha_ecards")
    record = item(issuer_code: "NCPRF", proposed_verification_code: "NCPRF-1")

    result, transport = check_online(record)

    assert_empty transport.requests
    assert_equal :needs_check, result.status
    assert_match "automatic check isn't on the issuer's own site", result.note
  end

  test "the site asked moments ago: needs a check now, and CheckJob tries again shortly" do
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write("verification/http/ecards.heart.org/recent", true, expires_in: 5.seconds)
    record = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE)

    result = nil
    transport = with_fake_sites(cache: cache) { with_auto_checks { result = check(record) } }

    assert_empty transport.requests
    assert_equal [ :unavailable, "busy" ], [ result.status, result.details["unavailable"] ]
    assert_recorded record, :needs_check, "automatic:aha_ecards"
    assert record.authenticity_note.end_with?("CertTrack will try again in a moment."), record.authenticity_note
    assert_enqueued_with job: Verification::CheckJob, args: [ record, { attempt: 1 } ]
  end

  test "after the last busy attempt nothing more is scheduled" do
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write("verification/http/ecards.heart.org/recent", true, expires_in: 5.seconds)
    record = item(issuer_code: "AHA", proposed_verification_code: AHA_CODE)

    with_fake_sites(cache: cache) { with_auto_checks { check(record, attempt: Verification::CheckJob::BUSY_ATTEMPTS) } }

    assert_no_enqueued_jobs only: Verification::CheckJob
    assert_not record.reload.authenticity_note.include?("try again")
  end

  # Rules 4 and 5

  test "an issuer that needs contacting: needs a check, saying so" do
    result = check(item(issuer_code: "NSC", proposed_verification_code: "SCN-1"))

    assert_equal :needs_check, result.status
    assert_equal "Contact National Safety Council to check this certificate (see the issuer's verification notes).", result.note
  end

  test "an unknown issuer with a code or link: needs a check" do
    assert_equal :needs_check, check(item(proposed_verification_code: "X-1")).status
    assert_equal :needs_check, check(item(proposed_verification_url: "example-training.com/verify")).status
  end

  test "an issuer's QR code alone is something to check with" do
    assert_equal :needs_check, check(item(barcodes: [ qr(REDCROSS_QR) ])).status
  end

  test "an issuer with no registry can't be verified, even with a code" do
    result = check(item(issuer_code: "EMPLOYER", proposed_verification_code: "FL-1"))

    assert_equal :cannot_verify, result.status
    assert_equal "Employer (in-house training) keeps no public registry, so this certificate can't be checked with the issuer.", result.note
    assert_not item.authenticity_flagged?
  end

  test "nothing to check with: can't be verified" do
    record = item(issuer_code: "REDCROSS")

    result = check(record)

    assert_equal :cannot_verify, result.status
    assert_equal "There's no verification code, link or QR code to check this certificate with.", result.note
    assert_recorded record, :cannot_verify, "rules"
  end

  # Rule 6

  test "a person's result is left alone, and nil returned, until force" do
    record = item(issuer_code: "REDCROSS", barcodes: [ qr(LOOKALIKE_QR) ])
    record.record_authenticity!(status: :verified, method: "person", note: "Checked on the phone", by: users(:manager))

    assert_nil check(record)
    assert_equal [ "verified", "person" ], [ record.reload.authenticity_status, record.authenticity_method ]

    assert_equal :suspicious, check(record, force: true).status
    assert_recorded record, :suspicious, "qr_link"
  end

  test "force with requested_at replaces only a person's result recorded by then" do
    record = item(issuer_code: "REDCROSS", barcodes: [ qr(LOOKALIKE_QR) ])
    clicked_at = Time.current
    travel 1.minute
    record.record_authenticity!(status: :not_found, method: "person", note: "No such certificate", by: users(:manager))

    assert_nil check(record, force: true, requested_at: clicked_at), "recorded after Check again was pressed"
    assert_equal [ "not_found", "person" ], [ record.reload.authenticity_status, record.authenticity_method ]

    assert_equal :suspicious, check(record, force: true, requested_at: Time.current).status
    assert_recorded record, :suspicious, "qr_link"
  end

  test "a person's result saved while the issuer's site was asked isn't overwritten" do
    certificate = certificates(:juan_first_aid)
    certificate.update!(certificate_issuer: issuer("OTIEC"), verification_code: "AB12CD34")
    meanwhile = lambda do |*|
      Certificate.where(id: certificate.id).update_all(authenticity_status: Certificate.authenticity_statuses["not_found"],
        authenticity_method: "person", authenticity_checked_at: Time.current, authenticity_note: "Called the training center")
      response(page("osha_card_portal_valid"))
    end

    result = nil
    transport = with_fake_sites(responder: meanwhile) { with_auto_checks { result = check(certificate) } }

    assert_equal 1, transport.requests.size
    assert_nil result
    certificate.reload
    assert_equal [ "not_found", "person", "Called the training center" ],
      [ certificate.authenticity_status, certificate.authenticity_method, certificate.authenticity_note ]
    assert_no_enqueued_jobs only: Verification::CheckJob
  end

  test "an automatic result is replaced by the next run" do
    record = item(issuer_code: "REDCROSS")
    check(record)
    record.update!(proposed_verification_code: "TEST123")

    assert_equal :needs_check, check(record).status
    assert_equal "needs_check", record.reload.authenticity_status
  end

  # Rule 7: a person's fake result turned back into needs a check because its details changed

  # A flagger card a person recorded Not found for code A128, then edited.
  def reset_certificate(**edit)
    member = CrewMember.create!(first_name: "Reset", last_name: "Holder")
    certificate = Certificate.create!(crew_member: member, certificate_type: certificate_types(:flagger),
      completed_on: Date.current - 30, verification_code: "A128")
    certificate.record_authenticity!(status: :not_found, method: "person", note: "Called ATSSA: no card A128", by: users(:manager))
    certificate.update!(**edit)
    assert_equal "details_changed", certificate.authenticity_method
    certificate
  end

  test "a reset stays needs a check, with its note and history, against a result from the rules alone" do
    { { verification_code: "" } => :cannot_verify, { verification_code: "A12B" } => :needs_check }.each do |edit, rules_say|
      certificate = reset_certificate(**edit)
      reset_note = certificate.authenticity_note
      reset_details = certificate.authenticity_details

      assert_nil check(certificate), "the rules would say #{rules_say}"

      certificate.reload
      assert_equal [ "needs_check", "details_changed", reset_note, reset_details ],
        [ certificate.authenticity_status, certificate.authenticity_method, certificate.authenticity_note, certificate.authenticity_details ]
      assert_equal "Called ATSSA: no card A128", reset_details["previous_note"]
      assert_equal 1, Certificate.where(id: certificate.id).authenticity_review_counts["needs_check"], "still on the list to check"
      assert_nil check(certificate, force: true), "nor does Check again: only a person's result or a definite answer settles it"
    end
  end

  test "a definite result replaces a reset, keeping what the person had recorded" do
    certificate = reset_certificate(verification_url: LOOKALIKE_QR)

    assert_equal :suspicious, check(certificate).status

    assert_recorded certificate, :suspicious, "verification_link"
    assert_equal({ "previous_status" => "not_found", "previous_checked_by_id" => users(:manager).id, "changed" => [ "verification link" ],
      "previous_note" => "Called ATSSA: no card A128" }, certificate.authenticity_details.slice("previous_status",
      "previous_checked_by_id", "changed", "previous_note"))
    assert_equal "redcross-verify.com", certificate.authenticity_details["link_host"]
    assert_match(/\AThe verification link points to redcross-verify\.com.*\. Before this check, a person had recorded “Not found by issuer”, but the verification link changed afterwards\.\z/,
      certificate.authenticity_note)
  end

  test "a busy issuer's site leaves a reset alone and is asked again shortly" do
    certificate = reset_certificate(certificate_issuer: issuer("AHA"), verification_code: AHA_CODE)
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write("verification/http/ecards.heart.org/recent", true, expires_in: 5.seconds)

    result = nil
    with_fake_sites(cache: cache) { with_auto_checks { result = check(certificate) } }

    assert_nil result
    assert_equal [ "needs_check", "details_changed" ], [ certificate.reload.authenticity_status, certificate.authenticity_method ]
    assert_enqueued_with job: Verification::CheckJob, args: [ certificate, { attempt: 1 } ]
  end

  # Certificates

  test "a certificate: its issuer, code, crew member's names and the QR codes given" do
    certificate = certificates(:juan_first_aid)
    certificate.crew_member.update!(preferred_name: "Johnny")
    certificate.update!(certificate_issuer: issuer("OTIEC"), verification_code: "AB12CD34")

    page_for_johnny = page("osha_card_portal_valid").sub("ORTIZ, JUAN", "Johnny Ortiz").sub("<dt>Issue Date</dt><dd>03/14/2025</dd>", "")
    result, transport = check_online(certificate, response(page_for_johnny))

    assert_equal :verified, result.status
    assert_equal "https://www.oshacardportal.com/portalapp/verify/AB12CD34", transport.requests.sole[:url]
    assert_recorded certificate, :verified, "automatic:osha_card_portal"

    assert_equal :suspicious, check(certificate, barcodes: [ qr(LOOKALIKE_QR) ]).status
    assert certificate.reload.authenticity_flagged_for_review?
    assert_equal "valid", certificate.compliance_status, "flagged for review: it still counts by its dates (~60 days)"
  end

  test "an automatic check never makes a certificate fake, and never replaces a person's fake until Check again" do
    certificate = certificates(:juan_first_aid)
    certificate.update!(certificate_issuer: issuer("OTIEC"), verification_code: "AB12CD34")

    check_online(certificate, response(page("osha_card_portal_not_valid")))
    assert_recorded certificate, :not_found, "automatic:osha_card_portal"
    assert certificate.authenticity_flagged_for_review?
    assert_equal "valid", certificate.compliance_status

    certificate.record_authenticity!(status: :not_found, method: "person", note: "Called the training center", by: users(:manager))
    assert_equal "fake", certificate.compliance_status
    result, transport = check_online(certificate, response(page("osha_card_portal_valid")))
    assert_nil result
    assert_empty transport.requests
    assert_equal [ "not_found", "person", "fake" ],
      [ certificate.reload.authenticity_status, certificate.authenticity_method, certificate.compliance_status ]

    check_online(certificate, response(page("osha_card_portal_not_valid")), force: true)
    assert_recorded certificate, :not_found, "automatic:osha_card_portal"
    assert_equal "valid", certificate.compliance_status, "Check again's automatic not found is only flagged for review"
  end

  test "a certificate without barcodes given has no QR codes" do
    certificate = certificates(:juan_osha30)
    certificate.update!(certificate_issuer: issuer("360TRAINING"), verification_url: TRAINING_QR)

    result = check(certificate)

    assert_equal :mismatch, result.status, "the 360training link's issue date isn't this certificate's completion date"
    assert_equal({ "holder_last_name" => "match", "completed_on" => "differs" }, result.details["compared"])
  end

  test "notes never hold names, codes or dates" do
    records = [
      item(issuer_code: "AHA", proposed_verification_code: AHA_CODE, holder_name_raw: "Maria Garcia"),
      item(issuer_code: "360TRAINING", holder_name_raw: "Juan Ortega", barcodes: [ qr(TRAINING_QR) ]),
      item(issuer_code: "REDCROSS", proposed_verification_code: "TEST123")
    ]
    replies = [ response(page("aha_ecards_found")) ]

    records.each do |record|
      result, = check_online(record, *replies.shift(1))
      assert_no_match PERSONAL, result.note
      assert_no_match PERSONAL, result.details.to_json
    end
  end

  test "an import item's result is written whole even when the job's copy of the item is stale" do
    record = item(barcodes: [ { "page" => 1, "text" => LOOKALIKE_QR } ], proposed_verification_code: "A1")
    check(record, network: false)
    assert_recorded record, :suspicious, "qr_link"

    job_copy = ImportItem.find(record.id) # loaded when the job starts; never reloaded for an item
    other = ImportItem.find(record.id)
    other.record_authenticity!(status: :not_found, method: "manual", note: "No such card", by: users(:manager))
    other.update!(proposed_verification_code: "B2") # a reviewer's edit while the job runs: back to needs_check
    assert_equal [ "needs_check", "details_changed" ], [ other.authenticity_status, other.authenticity_method ]

    assert_equal :suspicious, check(job_copy, network: false).status
    assert_recorded record, :suspicious, "qr_link"
    assert record.authenticity_flagged_for_review?
  end

  test "only import items and certificates are checked" do
    assert_raises(ArgumentError) { check(crew_members(:juan_ortiz)) }
  end
end
