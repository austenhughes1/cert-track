require "test_helper"

class Imports::IssuerMatcherTest < ActiveSupport::TestCase
  REDCROSS_QR = "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123".freeze
  TRAINING_QR = "https://verify.360training.com/qrcode-certificate-validation?enrollmentId=12345678&s_lname=Ortiz".freeze

  setup { CertificateIssuer.seed_defaults! }

  def match(code: nil, name: nil, urls: [])
    Imports::IssuerMatcher.new(code: code, name_as_printed: name, urls: urls).call
  end

  def issuer(code)
    CertificateIssuer.find_by_code!(code)
  end

  test "a QR link on an issuer's domain is a match, whatever code the model gave" do
    result = match(code: "AHA", name: "Example Safety Training LLC", urls: [ REDCROSS_QR ])

    assert_equal [ issuer("REDCROSS"), :matched, :domain ], [ result.issuer, result.match, result.source ]
    assert_equal({ "id" => issuer("REDCROSS").id, "name" => "American Red Cross", "similarity" => 1.0 }, result.suggestions.first)
  end

  test "a printed address without a scheme matches by its domain too" do
    result = match(urls: [ "nationaloshafoundation.com/certificate-verification" ])

    assert_equal [ issuer("NOF"), :matched, :domain ], [ result.issuer, result.match, result.source ]
  end

  test "with links to several issuers, the one the code names wins, else the first link's" do
    assert_equal issuer("360TRAINING"), match(code: "360training", urls: [ REDCROSS_QR, TRAINING_QR ]).issuer
    assert_equal issuer("REDCROSS"), match(code: "NOF", urls: [ REDCROSS_QR, TRAINING_QR ]).issuer
  end

  test "an active issuer's code is a match, case- and space-insensitive" do
    result = match(code: " redcross ", name: "Red Cross Training Services")

    assert_equal [ issuer("REDCROSS"), :matched, :code ], [ result.issuer, result.match, result.source ]
    assert_equal 1, result.suggestions.count { |suggestion| suggestion["id"] == issuer("REDCROSS").id }
  end

  test "lookalike and unrelated links match nothing, so the code or name decides" do
    result = match(code: "REDCROSS", urls: [ "https://redcross-verify.com/certificate?certnumber=TEST123", "https://example.com/brochure" ])

    assert_equal [ issuer("REDCROSS"), :matched, :code ], [ result.issuer, result.match, result.source ]
    assert_equal :unmatched, match(urls: [ "https://redcross-verify.com/certificate", "not a link", "" ]).match
  end

  test "without a link or known code, a printed name close to an issuer's is only a suggestion" do
    result = match(code: "BOGUS", name: "American Red Cros")

    assert_equal [ issuer("REDCROSS"), :suggested, :name ], [ result.issuer, result.match, result.source ]
    assert_operator result.suggestions.first["similarity"], :>=, CertificateIssuer::FUZZY_THRESHOLD
    assert_operator result.suggestions.first["similarity"], :<, 1.0
  end

  test "an alias counts for the fuzzy match" do
    result = match(name: "OSHA Campus")

    assert_equal [ issuer("360TRAINING"), :suggested ], [ result.issuer, result.match ]
  end

  test "an inactive issuer's code is only a suggestion, after any active candidates, and never matched by domain" do
    issuer("REDCROSS").update!(active: false)

    by_code = match(code: "REDCROSS", urls: [ REDCROSS_QR ])
    assert_equal [ issuer("REDCROSS"), :suggested, :code ], [ by_code.issuer, by_code.match, by_code.source ]
    assert_equal [ { "id" => issuer("REDCROSS").id, "name" => "American Red Cross", "similarity" => 1.0, "note" => "inactive issuer" } ],
      by_code.suggestions

    with_name = match(code: "REDCROSS", name: "National CPR Foundation")
    suggested = with_name.suggestions.map { |suggestion| CertificateIssuer.find(suggestion["id"]) }
    assert_equal [ issuer("NCPRF"), issuer("REDCROSS") ], [ suggested.first, suggested.last ]
    assert_equal [ issuer("NCPRF"), :suggested, :name ], [ with_name.issuer, with_name.match, with_name.source ]
  end

  test "nothing to go on is unmatched" do
    result = match(code: nil, name: "Example Safety Training LLC")

    assert_equal [ nil, :unmatched, [], nil ], [ result.issuer, result.match, result.suggestions, result.source ]
  end

  test "suggestions are capped" do
    5.times { |index| CertificateIssuer.create!(name: "Acme Safety Training #{index}", code: "ACME#{index}") }

    assert_equal Imports::IssuerMatcher::MAX_SUGGESTIONS, match(name: "Acme Safety Training").suggestions.size
  end

  test "code_in_link reads the certificate id from a known query parameter" do
    assert_equal "TEST123", Imports::IssuerMatcher.code_in_link(issuer("REDCROSS"), REDCROSS_QR)
    assert_equal "12345678", Imports::IssuerMatcher.code_in_link(issuer("360TRAINING"), TRAINING_QR), "parameter names ignore case"
    assert_equal "NOF 77", Imports::IssuerMatcher.code_in_link(issuer("NOF"),
      "https://www.nationaloshafoundation.com/certificate-verification/?x=1&certificate_id=NOF%2077")
  end

  test "code_in_link reads the {code} part of the issuer's link template" do
    assert_equal "AB12-CD", Imports::IssuerMatcher.code_in_link(issuer("OTIEC"), "http://oshacardportal.com/portalapp/verify/AB12-CD?src=qr")
    assert_nil Imports::IssuerMatcher.code_in_link(issuer("OTIEC"), "https://www.oshacardportal.com/portalapp/other/AB12")
  end

  test "code_in_link gives nil without a code, link or issuer, or for a value too long to be a code" do
    assert_nil Imports::IssuerMatcher.code_in_link(issuer("REDCROSS"), "https://www.redcross.org/take-a-class")
    assert_nil Imports::IssuerMatcher.code_in_link(issuer("REDCROSS"), nil)
    assert_nil Imports::IssuerMatcher.code_in_link(nil, REDCROSS_QR)
    assert_nil Imports::IssuerMatcher.code_in_link(issuer("REDCROSS"), "https://www.redcross.org/x?certnumber=#{"9" * 81}")
    assert_nil Imports::IssuerMatcher.code_in_link(issuer("REDCROSS"), "https://www.redcross.org/x?certnumber=%E0%A4%A")
  end
end
