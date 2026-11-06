require "test_helper"
require_relative "verification_test_support"

# The network checkers against the crafted pages in test/fixtures/files/verification/ (built from
# the Nov 4, 2026 research; synthetic names only), and the 360training QR details checker.
class Verification::CheckersTest < ActiveSupport::TestCase
  include VerificationTestSupport

  AHA = Verification::Checkers::AhaEcards
  NCPRF = Verification::Checkers::NationalCprFoundation
  NOF = Verification::Checkers::NationalOshaFoundation
  PORTAL = Verification::Checkers::OshaCardPortal
  QR_360 = Verification::Checkers::QrDetails360training

  TRAINING_QR = "https://verify.360training.com/qrcode-certificate-validation?enrollmentId=12345678&s_fname=Juan" \
    "&s_mname=A&s_lname=Ortiz&course=OSHA%2030-Hour%20Construction&issued=03/14/2025".freeze

  setup { seed_issuers }

  def check(klass, *replies, **options)
    result = nil
    transport = with_fake_sites(*replies) { result = checker_for(klass, **options).call }
    [ result, transport ]
  end

  test "Checkers.for maps every key to its class, which knows its key" do
    Verification::Checkers::KEYS.each do |key|
      klass = Verification::Checkers.for(key)
      assert_equal key, klass.key
      assert_operator klass, :<, Verification::Checkers::Base
    end
    assert_raises(KeyError) { Verification::Checkers.for("nope") }
  end

  test "every network checker's endpoint is HTTPS on its issuer's own domain" do
    { "AHA" => AHA, "NCPRF" => NCPRF, "NOF" => NOF, "OTIEC" => PORTAL }.each do |code, klass|
      assert klass::ENDPOINT.start_with?("https://"), klass.name
      assert issuer(code).owns_url?(klass::ENDPOINT), klass.name
      assert_equal klass.key, issuer(code).automatic_check
    end
  end

  # AHA eCards

  test "AHA: a found eCard with the holder's name and renewal month is verified" do
    result, transport = check(AHA, response(page("aha_ecards_found")), expires_on: Date.new(2027, 3, 31))

    assert_equal :verified, result.status
    assert_equal "automatic:aha_ecards", result.method
    assert_equal({ "issuer_status" => "Active", "compared" => { "holder" => "match", "expires_on" => "match" } }, result.details)
    assert_equal "AHA eCards found this certificate (status: Active), and its details match.", result.note
    request = transport.requests.sole
    assert_equal [ :post, "https://ecards.heart.org/Student/MyeCards/VerifyECards", "codes=212345678901" ],
      [ request[:method], request[:url], request[:body] ]
  end

  test "AHA: only the verification code is sent, never the name or dates" do
    _, transport = check(AHA, response(page("aha_ecards_found")), holder: "Juan Ortiz", completed_on: Date.new(2025, 3, 14))

    request = transport.requests.sole
    assert_no_match(/ortiz|juan|2025/i, request[:url] + request[:body].to_s)
  end

  test "AHA: a different name is a mismatch" do
    result, = check(AHA, response(page("aha_ecards_found")), holder: "Maria Garcia")

    assert_equal :mismatch, result.status
    assert_equal({ "holder" => "differs" }, result.details["compared"])
    assert_equal "AHA eCards found this certificate (status: Active), but its name doesn't match the certificate.", result.note
    assert_no_match(/garcia|ortiz/i, result.note)
  end

  test "AHA: a renewal month that isn't the certificate's expiry month is a mismatch" do
    result, = check(AHA, response(page("aha_ecards_found")), expires_on: Date.new(2026, 3, 31))

    assert_equal :mismatch, result.status
    assert_equal({ "holder" => "match", "expires_on" => "differs" }, result.details["compared"])
    assert_match "its expiry date doesn't match", result.note
  end

  test "AHA: an Invalid eCard is not found" do
    result, = check(AHA, response(page("aha_ecards_invalid")), code: "999999999999")

    assert_equal :not_found, result.status
    assert_equal({ "issuer_status" => "Invalid" }, result.details)
    assert_equal "AHA eCards has no certificate with this code.", result.note
  end

  test "AHA: an eCard without a name (not claimed yet) needs a check" do
    result, = check(AHA, response(page("aha_ecards_unclaimed")))

    assert_equal :needs_check, result.status
    assert_match "shows no name to compare", result.note
  end

  test "AHA: a page without the eCards table is unavailable" do
    result, = check(AHA, response(page("aha_ecards_unknown_layout")))

    assert_equal :unavailable, result.status
    assert_equal({ "unavailable" => "layout" }, result.details)
    assert_equal "The automatic check with AHA eCards didn't work. AHA eCards showed a page CertTrack doesn't recognise. " \
      "Open the verification page to check it by hand.", result.note
  end

  test "AHA: a code that isn't 12 digits is still sent" do
    result, transport = check(AHA, response(page("aha_ecards_invalid")), code: "AB-12")

    assert_equal :not_found, result.status
    assert_equal "codes=AB-12", transport.requests.sole[:body]
  end

  # National CPR Foundation

  test "NCPRF: the live site's results table is read for the row with this code" do
    result, = check(NCPRF, response(page("ncprf_found_table")), code: "5a1b2c", holder: "Juan A. Ortiz", completed_on: Date.new(2025, 3, 14))
    assert_equal :verified, result.status
    assert_equal({ "holder" => "match", "completed_on" => "match" }, result.details["compared"])

    other, = check(NCPRF, response(page("ncprf_found_table")), code: "5A1B2C", holder: "Li Chen", completed_on: Date.new(2025, 3, 14))
    assert_equal :mismatch, other.status, "another person's row must not satisfy this code"

    missing, = check(NCPRF, response(page("ncprf_found_table")), code: "NOTLISTED", holder: "Juan A. Ortiz", completed_on: Date.new(2025, 3, 14))
    assert_equal :unavailable, missing.status
  end

  test "NCPRF: a result with the holder's name and dates is verified" do
    result, transport = check(NCPRF, response(page("ncprf_found")), code: "NCPRF-1",
      completed_on: Date.new(2025, 3, 14), expires_on: Date.new(2027, 3, 14))

    assert_equal :verified, result.status
    assert_equal({ "holder" => "match", "completed_on" => "match", "expires_on" => "match" }, result.details["compared"])
    request = transport.requests.sole
    assert_equal "https://nationalcprfoundation.com/verify/", request[:url]
    assert_equal "certificate_code=NCPRF-1&email=&submit_user=Continue", request[:body]
  end

  test "NCPRF: a completion date more than a day off is a mismatch" do
    result, = check(NCPRF, response(page("ncprf_found")), code: "NCPRF-1", completed_on: Date.new(2025, 3, 20))

    assert_equal :mismatch, result.status
    assert_equal({ "holder" => "match", "completed_on" => "differs" }, result.details["compared"])
    assert_match "its completion date doesn't match", result.note
  end

  test "NCPRF: a different name and dates list every field that differs" do
    result, = check(NCPRF, response(page("ncprf_found")), code: "NCPRF-1", holder: "Li Chen",
      completed_on: Date.new(2024, 1, 2), expires_on: Date.new(2026, 1, 2))

    assert_equal :mismatch, result.status
    assert_match "its name, completion date, and expiry date don't match", result.note
  end

  test "NCPRF: No Results is not found" do
    result, = check(NCPRF, response(page("ncprf_no_results")), code: "NCPRF-0")

    assert_equal :not_found, result.status
  end

  test "NCPRF: the form shown again, without a result, is unavailable" do
    result, = check(NCPRF, response(page("ncprf_form_only")), code: "NCPRF-1")

    assert_equal :unavailable, result.status
    assert_equal "layout", result.details["unavailable"]
  end

  # National OSHA Foundation

  test "NOF: a row with the holder's name and completion date is verified" do
    result, transport = check(NOF, response(page("nof_found")), code: "NOF 77", completed_on: Date.new(2025, 3, 15))

    assert_equal :verified, result.status
    assert_equal({ "holder" => "match", "completed_on" => "match" }, result.details["compared"])
    assert_equal "https://www.nationaloshafoundation.com/certificate-verification/?certificate_id=NOF+77", transport.requests.sole[:url]
    assert_equal :get, transport.requests.sole[:method]
  end

  test "NOF: a completion date more than a day off is a mismatch" do
    result, = check(NOF, response(page("nof_found")), code: "NOF-77", completed_on: Date.new(2025, 3, 16))

    assert_equal :mismatch, result.status
  end

  test "NOF: an HTTP 500 or a critical error page is unavailable, never not found" do
    result, = check(NOF, response(page("nof_critical_error"), status: 500), code: "NOF-77")
    assert_equal :unavailable, result.status
    assert_match "answered with an error (HTTP 500)", result.note

    result, = check(NOF, response(page("nof_critical_error")), code: "NOF-77")
    assert_equal :unavailable, result.status
    assert_match "showed an error page", result.note
  end

  test "NOF: an explicit no-records message is not found" do
    result, = check(NOF, response(page("nof_no_records")), code: "NOF-0")

    assert_equal :not_found, result.status
  end

  test "NOF: an empty page is unavailable" do
    result, = check(NOF, response("<html><body><h1>Certificate Verification</h1></body></html>"), code: "NOF-0")

    assert_equal :unavailable, result.status
  end

  # OSHA Card Portal

  test "OSHA Card Portal: VALID with the holder's name is verified" do
    result, transport = check(PORTAL, response(page("osha_card_portal_valid")), code: "AB12/CD34",
      holder: [ "Juan Ortiz" ], completed_on: Date.new(2025, 3, 14))

    assert_equal :verified, result.status
    assert_equal({ "issuer_status" => "VALID", "compared" => { "holder" => "match", "completed_on" => "match" } }, result.details)
    assert_equal "https://www.oshacardportal.com/portalapp/verify/AB12%2FCD34", transport.requests.sole[:url]
  end

  test "OSHA Card Portal: VALID with another name is a mismatch" do
    result, = check(PORTAL, response(page("osha_card_portal_valid")), code: "AB12CD34", holder: "Juan Ortega")

    assert_equal :mismatch, result.status
  end

  test "OSHA Card Portal: NOT VALID is not found" do
    result, = check(PORTAL, response(page("osha_card_portal_not_valid")), code: "ZZ999999")

    assert_equal :not_found, result.status
    assert_equal({ "issuer_status" => "NOT VALID" }, result.details)
  end

  test "OSHA Card Portal: VALID without a name needs a check (a forged card can reuse a number)" do
    result, = check(PORTAL, response(page("osha_card_portal_valid_no_name")), code: "AB12CD34")

    assert_equal :needs_check, result.status
    assert_equal "VALID", result.details["issuer_status"]
  end

  test "OSHA Card Portal: a page saying neither is unavailable" do
    result, = check(PORTAL, response(page("aha_ecards_unknown_layout")), code: "AB12CD34")

    assert_equal :unavailable, result.status
  end

  # Failures every network checker shares

  test "without a code nothing is sent and the check is unavailable" do
    result, transport = check(PORTAL, code: nil)

    assert_equal :unavailable, result.status
    assert_equal({ "unavailable" => "no_code" }, result.details)
    assert_empty transport.requests
  end

  test "a refused, timed-out, throttled or too-large request is unavailable with a note saying why" do
    {
      Verification::HttpClient::TimedOut.new("www.oshacardportal.com didn't answer within 10 seconds.") => [ "timeout", "didn't answer within 10 seconds" ],
      Verification::HttpClient::Failed.new("www.oshacardportal.com couldn't be reached.") => [ "unreachable", "couldn't be reached" ],
      response("x" * (1.megabyte + 1)) => [ "too_large", "larger than 1 MB" ],
      response(status: 302, headers: { "location" => "https://example.com/" }) => [ "refused", "redirected the check to example.com" ],
      response("blocked", status: 403) => [ "blocked", "OSHA Card Portal refused it (HTTP 403)" ],
      response("busy", status: 429) => [ "blocked", "refused it (HTTP 429)" ],
      response("down", status: 503) => [ "http_error", "answered with an error (HTTP 503)" ]
    }.each do |reply, (reason, words)|
      result, = check(PORTAL, reply, code: "AB12CD34")

      assert_equal :unavailable, result.status, reason
      assert_equal reason, result.details["unavailable"], reason
      assert_match words, result.note
      assert result.note.end_with?("Open the verification page to check it by hand."), result.note
    end
  end

  test "a second check with one site within 5 seconds is unavailable as busy" do
    cache = ActiveSupport::Cache::MemoryStore.new
    results = []
    with_fake_sites(responder: ->(*) { response(page("osha_card_portal_valid")) }, cache: cache) do
      2.times { results << checker_for(PORTAL, code: "AB12CD34").call }
    end

    assert_equal :verified, results.first.status
    assert_equal [ :unavailable, "busy" ], [ results.last.status, results.last.details["unavailable"] ]
  end

  # 360training QR details (local)

  test "360training: matching QR details need a check, with the note PLAN.md gives" do
    result = checker_for(QR_360, code: nil, completed_on: Date.new(2025, 3, 14), barcodes: [ qr(TRAINING_QR) ]).call

    assert_equal :needs_check, result.status
    assert_equal "qr_details:qr_details_360training", result.method
    assert_equal "The QR code's details match the certificate; open the link to confirm with 360training.", result.note
    assert_equal({ "compared" => { "holder_last_name" => "match", "completed_on" => "match" } }, result.details)
  end

  test "360training: another last name in the QR link is a mismatch" do
    result = checker_for(QR_360, holder: "Juan Ortega", barcodes: [ qr(TRAINING_QR) ]).call

    assert_equal :mismatch, result.status
    assert_equal "The 360training QR code's last name doesn't match the certificate.", result.note
  end

  test "360training: a first name that differs isn't a mismatch (rule 2 compares the last name)" do
    result = checker_for(QR_360, holder: "Pedro Ortiz", barcodes: [ qr(TRAINING_QR) ]).call

    assert_equal :needs_check, result.status
  end

  test "360training: an issue date more than a day from the completion date is a mismatch" do
    result = checker_for(QR_360, completed_on: Date.new(2025, 3, 16), barcodes: [ qr(TRAINING_QR) ]).call

    assert_equal :mismatch, result.status
    assert_equal({ "holder_last_name" => "match", "completed_on" => "differs" }, result.details["compared"])
    assert_match "issue date doesn't match", result.note

    assert_equal :needs_check, checker_for(QR_360, completed_on: Date.new(2025, 3, 15), barcodes: [ qr(TRAINING_QR) ]).call.status
  end

  test "360training: the QR link may come from the verification link instead of the QR codes" do
    result = checker_for(QR_360, holder: "Juan Ortega", verification_url: TRAINING_QR).call

    assert_equal :mismatch, result.status
  end

  test "360training: without such a QR link there is nothing to compare, so it returns nil and Run's other rules decide" do
    [ [], [ qr("https://example.com/brochure") ], [ qr("https://verify.360training.com/qrcode-certificate-validation?enrollmentId=1") ],
      [ qr("https://verify.360training.com@example.com/qrcode-certificate-validation?s_lname=Ortiz") ] ].each do |barcodes|
      assert_nil checker_for(QR_360, barcodes: barcodes).call, barcodes.inspect
    end
  end

  test "360training: with several people's QR codes, a mismatch means none of them matches the holder" do
    marias = TRAINING_QR.sub("s_fname=Juan", "s_fname=Maria").sub("s_lname=Ortiz", "s_lname=Garcia")

    result = checker_for(QR_360, holder: "Maria Garcia", completed_on: Date.new(2025, 3, 14), barcodes: [ qr(TRAINING_QR), qr(marias) ]).call
    assert_equal :needs_check, result.status
    assert_equal({ "holder_last_name" => "match", "completed_on" => "match" }, result.details["compared"])

    assert_equal :mismatch, checker_for(QR_360, holder: "Li Chen", barcodes: [ qr(TRAINING_QR), qr(marias) ]).call.status
  end

  test "360training: nothing is sent anywhere" do
    transport = with_fake_sites { checker_for(QR_360, barcodes: [ qr(TRAINING_QR) ]).call }

    assert_empty transport.requests
  end
end
