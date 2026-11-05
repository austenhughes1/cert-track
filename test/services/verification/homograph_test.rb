require "test_helper"

class Verification::HomographTest < ActiveSupport::TestCase
  test "fold maps look-alike letters from other alphabets to a-z" do
    {
      "www.redсrоss.org" => "www.redcross.org",   # Cyrillic с and о
      "раyраl.com" => "paypal.com",     # Cyrillic р and а
      "οσha.gov" => "oσha.gov",               # Greek ο maps, σ isn't a look-alike and stays
      "ｒｅｄｃｒｏｓｓ.org" => "redcross.org", # full-width
      "REDСROSS.ORG" => "redcross.org",               # upper case, Cyrillic С
      "café.com" => "cafe.com",                       # accents off
      "redcross.org" => "redcross.org"
    }.each do |host, folded|
      assert_equal folded, Verification::Homograph.fold(host), host
    end
  end

  test "fold decodes punycode labels (RFC 3492)" do
    {
      "xn--mnchen-3ya.de" => "munchen.de",       # münchen
      "xn--redcrss-ejg.org" => "redcross.org",   # redcrоss
      "xn--80ak6aa92e.com" => "apple.com",       # аррӏе, all Cyrillic
      "www.xn--hart-v4d.org" => "www.heart.org"  # hеart
    }.each do |host, folded|
      assert_equal folded, Verification::Homograph.fold(host), host
    end
  end

  test "a label that isn't valid punycode is kept as written" do
    %w[xn-- xn--! xn--zz9zz9zz9zz9zz9zz9zz9].each do |label|
      assert_kind_of String, Verification::Homograph.fold("#{label}.com"), label
    end
    assert_equal "xn--!.com", Verification::Homograph.fold("xn--!.com")
    assert_nil Verification::Homograph.decode_label("redcross")
    assert_equal "münchen", Verification::Homograph.decode_label("xn--mnchen-3ya")
  end

  test "international: letters outside a-z, as text or punycode" do
    assert Verification::Homograph.international?("redсross.org")
    assert Verification::Homograph.international?("www.XN--mnchen-3ya.de")
    assert_not Verification::Homograph.international?("redcross.org")
    assert_not Verification::Homograph.international?("")
  end
end
