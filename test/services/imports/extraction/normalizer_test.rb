require "test_helper"

class Imports::Extraction::NormalizerTest < ActiveSupport::TestCase
  CODES = %w[OSHA30 FLAGGER].freeze

  test "a clean reply passes through in the contract shape" do
    raw = { "certificates" => [ certificate ], "non_certificate_pages" => [ 2 ] }

    assert_equal({
      "certificates" => [ {
        "pages" => [ 1 ], "holder_name" => "Juan A. Ortiz", "certificate_type_code" => "OSHA30",
        "certificate_name_as_printed" => "OSHA 30-Hour Construction", "issuer" => "Example Safety Training LLC",
        "certificate_issuer_code" => nil, "certificate_number" => "30-1234567", "verification_code" => nil,
        "verification_url" => nil, "completed_on" => "2025-03-14", "expires_on" => nil, "validity_months" => nil, "no_expiration" => false,
        "confidence" => 0.92, "notes" => "No expiration printed"
      } ],
      "non_certificate_pages" => [ 2 ]
    }, normalize(raw, pages: [ 1, 2 ]))
  end

  test "unknown or inactive codes become null with a note; codes are case-insensitive" do
    data = normalize({ "certificates" => [ certificate("certificate_type_code" => "osha30 "),
      certificate("certificate_type_code" => "HAZWOPER40", "pages" => [ 2 ]) ] }, pages: [ 1, 2 ])

    assert_equal [ "OSHA30", nil ], data["certificates"].map { |entry| entry["certificate_type_code"] }
    assert_match 'unknown type code "HAZWOPER40"', data["certificates"].last["notes"]
  end

  test "pages are clamped to the pages the call covered" do
    data = normalize({ "certificates" => [ certificate("pages" => [ 0, 3, "2", 2, 99, "x" ]) ] }, pages: [ 2, 3 ])
    assert_equal [ 2, 3 ], data["certificates"].sole["pages"]

    data = normalize({ "certificates" => [ certificate("pages" => [ 7 ]) ] }, pages: [ 4, 5 ])
    assert_equal [ 4, 5 ], data["certificates"].sole["pages"], "no usable page means every page of the call"
  end

  test "dates must be real ISO dates; anything else is dropped with a note and kept as unreadable" do
    data = normalize({ "certificates" => [ certificate("completed_on" => "03/14/2025", "expires_on" => "2025-02-30") ] })
    entry = data["certificates"].sole

    assert_nil entry["completed_on"]
    assert_nil entry["expires_on"]
    assert_match 'Unreadable completed_on "03/14/2025" dropped.', entry["notes"]
    assert_match "expires_on", entry["notes"]
    assert_equal({ "completed_on" => "03/14/2025", "expires_on" => "2025-02-30" }, entry["unreadable"],
      "kept so the pipeline can tell a printed but unreadable date from no date")

    data = normalize({ "certificates" => [ certificate("completed_on" => "2025-03-14T00:00:00Z", "expires_on" => "2028-3-1") ] })
    assert_equal "2025-03-14", data["certificates"].sole["completed_on"]
    assert_nil data["certificates"].sole["expires_on"]
    assert_equal({ "expires_on" => "2028-3-1" }, data["certificates"].sole["unreadable"])

    entry = normalize({ "certificates" => [ certificate("expires_on" => "EXP 06/#{"2027 " * 20}") ] })["certificates"].sole
    assert_operator entry["unreadable"]["expires_on"].length, :<=, Imports::Extraction::Normalizer::UNREADABLE_LIMIT
    assert_not normalize({ "certificates" => [ certificate ] })["certificates"].sole.key?("unreadable"), "only there when a date was dropped"
  end

  test "an expiry that says there is none is not printed, so it is null with a note but not unreadable" do
    wordings = [ "Never", "NEVER EXPIRES", "Expires: Never", "Expiration Date: never", "Does not expire", "Doesn't expire.",
      "doesnt expire", "No expiration", "No Expiration Date", "No expiry", "Non-expiring", "Lifetime", "Valid for life",
      "Permanent", "Valid indefinitely", "Not applicable", "Expires: N/A" ]

    wordings.each do |wording|
      entry = normalize({ "certificates" => [ certificate("expires_on" => wording, "notes" => nil) ] })["certificates"].sole

      assert_nil entry["expires_on"], wording
      assert_not entry.key?("unreadable"), "#{wording.inspect} is not an unreadable date"
      assert_equal "No expiry date printed (the card says #{wording.inspect}).", entry["notes"]
      assert_equal !wording.match?(/N\/A|Not applicable/), entry["no_expiration"], wording
    end
  end

  test "no_expiration needs an explicit statement, and a read date beats it" do
    read = ->(attrs) { normalize({ "certificates" => [ certificate(**attrs) ] })["certificates"].sole }

    assert_equal false, read.call("expires_on" => nil)["no_expiration"]
    assert_equal true, read.call("expires_on" => nil, "no_expiration" => true)["no_expiration"]
    assert_equal false, read.call("expires_on" => "2027-03-14", "no_expiration" => true)["no_expiration"]
  end

  test "validity_months is a whole number of months in a sane range" do
    read = ->(value) { normalize({ "certificates" => [ certificate("validity_months" => value) ] })["certificates"].sole["validity_months"] }

    assert_equal [ 24, 12, 24, 24, 24 ], [ 24, 12.0, "24", "24 months", "2 years" ].map(&read)
    assert_equal [ nil, nil, nil, nil, nil ], [ nil, 0, 1.5, "soon", 500 ].map(&read)
  end

  test "only a whole no-expiry wording counts, and only for the expiry" do
    [ "Never before 2027", "06/2027", "Exp 2O27", "Expires: 06/2027", "Valid until 2027-06", "Life", "See back" ].each do |text|
      entry = normalize({ "certificates" => [ certificate("expires_on" => text) ] })["certificates"].sole
      assert_equal({ "expires_on" => text }, entry["unreadable"], text)
    end

    entry = normalize({ "certificates" => [ certificate("completed_on" => "Never") ] })["certificates"].sole
    assert_equal({ "completed_on" => "Never" }, entry["unreadable"])
  end

  test "confidence is clamped to 0..1, percentages are scaled and missing is 0" do
    values = [ 1.0, -0.2, "0.874", "92", "85%", 250, nil, "high" ].map do |confidence|
      normalize({ "certificates" => [ certificate("confidence" => confidence) ] })["certificates"].sole["confidence"]
    end

    assert_equal [ 1.0, 0.0, 0.87, 0.92, 0.85, 1.0, 0.0, 0.0 ], values
  end

  test "confidence is rounded down, so nothing under 0.85 reaches the auto-accept threshold" do
    values = [ 0.849, 0.846, 0.845, "84.9%", 0.85, 0.29, 0.999 ].map do |confidence|
      normalize({ "certificates" => [ certificate("confidence" => confidence) ] })["certificates"].sole["confidence"]
    end

    assert_equal [ 0.84, 0.84, 0.84, 0.84, 0.85, 0.29, 0.99 ], values
  end

  test "string placeholders become null and long strings are capped" do
    entry = normalize({ "certificates" => [ certificate("issuer" => "N/A", "certificate_number" => "null",
      "notes" => " ", "holder_name" => "#{"Juan " * 50}Ortiz", "certificate_name_as_printed" => { "x" => 1 }) ] })["certificates"].sole

    assert_nil entry["issuer"]
    assert_nil entry["certificate_number"]
    assert_nil entry["certificate_name_as_printed"]
    assert_operator entry["holder_name"].length, :<=, 120
    assert_nil entry["notes"]
  end

  test "empty entries are dropped and their pages count as non-certificate pages" do
    empty = { "pages" => [ 2 ], "holder_name" => nil, "confidence" => 0.4 }
    data = normalize({ "certificates" => [ certificate, empty, "junk" ], "non_certificate_pages" => [ 1, 3, 9 ] }, pages: [ 1, 2, 3 ])

    assert_equal 1, data["certificates"].size
    assert_equal [ 2, 3 ], data["non_certificate_pages"], "page 1 holds a certificate; page 9 is not in the file"
  end

  test "pages nobody mentions are non-certificate pages" do
    data = normalize({ "certificates" => [ certificate ] }, pages: [ 1, 2 ])

    assert_equal [ 2 ], data["non_certificate_pages"]
  end

  test "an issuer code is kept only when it is an active issuer's, case-insensitive, else null with a note" do
    data = normalize({ "certificates" => [ certificate("certificate_issuer_code" => "redcross "),
      certificate("certificate_issuer_code" => "OSHA", "pages" => [ 2 ]) ] }, pages: [ 1, 2 ], issuer_codes: %w[REDCROSS NOF])

    assert_equal [ "REDCROSS", nil ], data["certificates"].map { |entry| entry["certificate_issuer_code"] }
    assert_match 'unknown issuer code "OSHA"', data["certificates"].last["notes"]
  end

  test "without issuer_codes, the active issuers' codes are looked up when a reply names one" do
    CertificateIssuer.create!(name: "American Red Cross", code: "REDCROSS")
    CertificateIssuer.create!(name: "Retired Provider", code: "RETIRED", active: false)
    normalizer = Imports::Extraction::Normalizer.new(pages: [ 1 ], codes: CODES)

    codes = %w[REDCROSS RETIRED].map do |code|
      normalizer.call("certificates" => [ certificate("certificate_issuer_code" => code) ])["certificates"].sole["certificate_issuer_code"]
    end
    assert_equal [ "REDCROSS", nil ], codes
  end

  test "verification codes are kept as printed, but never cut short" do
    entry = normalize({ "certificates" => [ certificate("verification_code" => "  RC-123  456 ") ] })["certificates"].sole
    assert_equal "RC-123 456", entry["verification_code"]

    [ "N/A", "", "9" * 81, { "code" => "1" } ].each do |value|
      assert_nil normalize({ "certificates" => [ certificate("verification_code" => value) ] })["certificates"].sole["verification_code"], value.inspect
    end
  end

  test "a verification link must look like a web address; OCR's spaces are taken out" do
    {
      "redcross.org/confirm" => "redcross.org/confirm",
      "https://www.redcross.org/take-a-class/ qrcode?certnumber=1" => "https://www.redcross.org/take-a-class/qrcode?certnumber=1",
      "WWW.ATSSA.COM/verify" => "WWW.ATSSA.COM/verify",
      "info@redcross.org" => nil,
      "Call 1-800-621-7615" => nil,
      "30.5" => nil,
      "ftp://files.example.com" => nil,
      "Scan the QR code" => nil,
      "unknown" => nil,
      "https://#{"a" * 500}.com" => nil
    }.each do |printed, expected|
      actual = normalize({ "certificates" => [ certificate("verification_url" => printed) ] })["certificates"].sole["verification_url"]
      expected.nil? ? assert_nil(actual, printed) : assert_equal(expected, actual, printed)
    end
  end

  test "a bare array or garbage still yields the contract shape" do
    assert_equal 1, normalize([ certificate ])["certificates"].size
    assert_equal({ "certificates" => [], "non_certificate_pages" => [ 1 ] }, normalize("nonsense"))
    assert_equal({ "certificates" => [], "non_certificate_pages" => [ 1 ] }, normalize({ "certificates" => "none" }))
  end

  private
    def normalize(raw, pages: [ 1 ], issuer_codes: [])
      Imports::Extraction::Normalizer.new(pages: pages, codes: CODES, issuer_codes: issuer_codes).call(raw)
    end

    def certificate(overrides = {})
      {
        "pages" => [ 1 ], "holder_name" => "Juan A. Ortiz", "certificate_type_code" => "OSHA30",
        "certificate_name_as_printed" => "OSHA 30-Hour Construction", "issuer" => "Example Safety Training LLC",
        "certificate_number" => "30-1234567", "completed_on" => "2025-03-14", "expires_on" => nil,
        "confidence" => 0.92, "notes" => "No expiration printed"
      }.merge(overrides)
    end
end
