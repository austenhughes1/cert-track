require "test_helper"
require_relative "verification_test_support"

class Verification::QrLinkTest < ActiveSupport::TestCase
  include VerificationTestSupport

  TRAINING_QR = "https://verify.360training.com/qrcode-certificate-validation?enrollmentId=12345678&s_fname=Juan" \
    "&s_mname=A&s_lname=Ortiz&course=OSHA%2030-Hour%20Construction&issued=03/14/2025".freeze

  setup { seed_issuers }

  test "a Red Cross QR link: domain, issuer and the certnumber code" do
    link = Verification::QrLink.parse("https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123")

    assert_equal "redcross.org", link.host
    assert_equal "redcross.org", link.domain
    assert_equal issuer("REDCROSS"), link.issuer
    assert_equal "TEST123", link.code
    assert_nil link.holder
  end

  test "a 360training QR link carries the holder's details" do
    link = Verification::QrLink.parse(TRAINING_QR)

    assert_equal "verify.360training.com", link.host
    assert_equal "360training.com", link.domain
    assert_equal issuer("360TRAINING"), link.issuer
    assert_equal "12345678", link.code
    holder = link.holder
    assert_equal [ "Juan", "A", "Ortiz" ], [ holder.first_name, holder.middle_name, holder.last_name ]
    assert_equal "Juan A Ortiz", holder.name
    assert_equal "OSHA 30-Hour Construction", holder.course
    assert_equal Date.new(2025, 3, 14), holder.issued_on
  end

  test "the code comes from any of the known query parameters, whatever their letter case" do
    {
      "https://www.nationaloshafoundation.com/certificate-verification/?certificate_id=NOF-77" => "NOF-77",
      "https://example.com/v?CertNumber=A1" => "A1",
      "https://example.com/v?cid=C-9&id=ignored" => "C-9",
      "https://example.com/v?code=XYZ9" => "XYZ9",
      "https://example.com/v?id=42" => "42",
      "https://example.com/v?certificateNumber=CN-1" => "CN-1",
      "https://example.com/v?ENROLLMENTID=E-5" => "E-5"
    }.each do |url, code|
      assert_equal code, Verification::QrLink.parse(url).code, url
    end
  end

  test "the first parameter in CODE_PARAMS order wins" do
    link = Verification::QrLink.parse("https://example.com/v?id=2&certnumber=1")

    assert_equal "1", link.code
  end

  test "path-style links: the code is the segment after verify or cert" do
    {
      "https://www.oshacardportal.com/portalapp/verify/AB12CD34" => "AB12CD34",
      "https://www.verifycco.org/cert/1234567" => "1234567",
      "https://example-training.com/certificates/verify/2025-0042" => "2025-0042"
    }.each do |url, code|
      assert_equal code, Verification::QrLink.parse(url).code, url
    end
  end

  test "a path that is not a verification link has no code" do
    %w[https://example.com/brochure https://example.com/about/team https://example.com/verify/start
       https://www.redcross.org/take-a-class].each do |url|
      assert_nil Verification::QrLink.parse(url).code, url
    end
  end

  test "the issuer's link_template gives the code even without a verify segment" do
    issuer("NSC").update!(link_template: "https://www.nsc.org/check/{code}/details")

    assert_equal "SCN-551", Verification::QrLink.parse("https://www.nsc.org/check/SCN-551/details").code
  end

  test "bare addresses and http links are read as https" do
    assert_equal "https://redcross.org/take-a-class/qrcode?certnumber=T1", Verification::QrLink.parse("redcross.org/take-a-class/qrcode?certnumber=T1").url
    assert_equal "https://example.com/x", Verification::QrLink.parse("http://example.com/x").url
    assert_equal "https://example.com/v?id=9", Verification::QrLink.parse("Verify at: https://example.com/v?id=9").url
  end

  test "text that isn't a web address is nil" do
    [ nil, "", "TEST123", "Juan A. Ortiz OSHA 30", "WIFI:S:guest;T:WPA;P:secret;;", "mailto:a@b" ].each do |text|
      assert_nil Verification::QrLink.parse(text), text.inspect
    end
  end

  test "a bare dotted word is a web address only when it ends in a letter top-level domain" do
    %w[2025.03.14 AB12.3456 10.5].each do |text|
      assert_nil Verification::QrLink.parse(text), text
    end
    assert Verification::QrLink.parse("redcross.org/x").bare?
    assert_not Verification::QrLink.parse("https://redcross.org/x").bare?
    assert_equal "1.2.3.4", Verification::QrLink.parse("https://1.2.3.4/x").host, "written as a link, any host is read"
  end

  test "a link with text before an @ hides its real host" do
    link = Verification::QrLink.parse("https://www.redcross.org@verify-now.net/c/1")

    assert_equal "verify-now.net", link.host
    assert link.hidden_host?
    assert_not Verification::QrLink.parse("https://www.redcross.org/c/1").hidden_host?
  end

  test "unreadable_host: an http(s) address whose host has letters outside a-z" do
    assert_nil Verification::QrLink.parse("https://www.red\u0441ross.org/x"), "URI can't read it"
    {
      "https://www.red\u0441ross.org/take-a-class/qrcode?certnumber=1" => "red\u0441ross.org",
      "Scan: http://m\u00FCnchen-schulung.de" => "m\u00FCnchen-schulung.de",
      "https://x@red\u0441ross.org:443/" => "red\u0441ross.org"
    }.each do |text, host|
      assert_equal host, Verification::QrLink.unreadable_host(text), text
    end
    [ nil, "", "https://www.redcross.org/x", "Jos\u00E9.Ortiz", "Jos\u00E9 Ortiz", "https://\u00E9t\u00E9" ].each do |text|
      assert_nil Verification::QrLink.unreadable_host(text), text.inspect
    end
  end

  test "a link to an unknown site has no issuer" do
    assert_nil Verification::QrLink.parse("https://redcross-verify.com/certificate?certnumber=TEST123").issuer
  end

  test "holder details without a last name are no holder; an unreadable date is no date" do
    assert_nil Verification::QrLink.parse("https://verify.360training.com/q?enrollmentId=1&s_fname=Juan").holder

    holder = Verification::QrLink.parse("https://verify.360training.com/q?s_lname=Ortiz&issued=sometime").holder
    assert_equal "Ortiz", holder.last_name
    assert_nil holder.issued_on
  end
end
