require "test_helper"

class Imports::Extraction::NormalizerTest < ActiveSupport::TestCase
  CODES = %w[OSHA30 FLAGGER].freeze

  test "a clean reply passes through in the contract shape" do
    raw = { "certificates" => [ certificate ], "non_certificate_pages" => [ 2 ] }

    assert_equal({
      "certificates" => [ {
        "pages" => [ 1 ], "holder_name" => "Juan A. Ortiz", "certificate_type_code" => "OSHA30",
        "certificate_name_as_printed" => "OSHA 30-Hour Construction", "issuer" => "Example Safety Training LLC",
        "certificate_number" => "30-1234567", "completed_on" => "2025-03-14", "expires_on" => nil,
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
    end
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

  test "a bare array or garbage still yields the contract shape" do
    assert_equal 1, normalize([ certificate ])["certificates"].size
    assert_equal({ "certificates" => [], "non_certificate_pages" => [ 1 ] }, normalize("nonsense"))
    assert_equal({ "certificates" => [], "non_certificate_pages" => [ 1 ] }, normalize({ "certificates" => "none" }))
  end

  private
    def normalize(raw, pages: [ 1 ])
      Imports::Extraction::Normalizer.new(pages: pages, codes: CODES).call(raw)
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
