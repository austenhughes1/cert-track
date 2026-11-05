require "test_helper"
require_relative "verification_test_support"

class Verification::LookalikeTest < ActiveSupport::TestCase
  include VerificationTestSupport

  # The default issuers' domains (config/certificate_issuers.yml).
  setup do
    domains = YAML.safe_load_file(CertificateIssuer::DEFAULTS_FILE).flat_map { |issuer| Array(issuer["domains"]) }
    @lookalike = Verification::Lookalike.new(domains)
  end

  test "an issuer's own domain and any of its subdomains are not lookalikes" do
    %w[redcross.org www.redcross.org https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123
       verify.360training.com https://verify.360training.com/qrcode-certificate-validation?enrollmentId=1
       ecards.heart.org www.nationaloshafoundation.com www.oshacardportal.com verify.usfotiec.org
       nwsa.useclarus.com WWW.REDCROSS.ORG.].each do |host|
      assert_nil @lookalike.imitated_domain(host), host
      assert @lookalike.known?(host), host
    end
  end

  test "a host containing an issuer's distinctive name is a lookalike" do
    {
      "redcross-verify.com" => "redcross.org",
      "https://redcross-verify.com/certificate?certnumber=TEST123" => "redcross.org",
      "verify-redcross.net" => "redcross.org",
      "red-cross-certificates.com" => "redcross.org",
      "redcross.org.cert-check.info" => "redcross.org",
      "360training-verify.com" => "360training.com",
      "my360training.net" => "360training.com",
      "nationaloshafoundation-certs.com" => "nationaloshafoundation.com",
      "clicksafety.verify-now.co" => "clicksafety.com",
      "oshacardportal.help" => "oshacardportal.com"
    }.each do |host, imitated|
      assert_equal imitated, @lookalike.imitated_domain(host), host
      assert @lookalike.lookalike?(host), host
      assert_not @lookalike.known?(host), host
    end
  end

  test "a domain a letter or two away from an issuer's is a lookalike" do
    {
      "redcros.org" => "redcross.org",
      "redcorss.org" => "redcross.org",
      "www.redcrosss.org" => "redcross.org",
      "360trainning.com" => "360training.com",
      "360traning.com" => "360training.com",
      "nationaloshafoundaton.com" => "nationaloshafoundation.com",
      "hearts.org" => "heart.org",
      "ipaff.org" => "ipaf.org"
    }.each do |host, imitated|
      assert_equal imitated, @lookalike.imitated_domain(host), host
    end
  end

  test "the same name with another ending is a lookalike, even for short names" do
    {
      "heart.com" => "heart.org",
      "ecards.heart.net" => "heart.org",
      "redcross.com" => "redcross.org",
      "360training.net" => "360training.com",
      "nsc.com" => "nsc.org",
      "redcross.co.uk" => "redcross.org"
    }.each do |host, imitated|
      assert_equal imitated, @lookalike.imitated_domain(host), host
    end
  end

  test "a host spelled with look-alike letters, as text or punycode, is a lookalike" do
    {
      "www.red\u0441r\u043Ess.org" => "redcross.org",            # Cyrillic с and о: reads the same
      "xn--redcrss-ejg.org" => "redcross.org",                    # punycode for redcrоss.org
      "https://www.xn--redrss-zqfw.org/take-a-class" => "redcross.org",
      "xn--hart-v4d.org" => "heart.org",                          # hеart.org
      "xn--360trining-3qi.com" => "360training.com",
      "\uFF52\uFF45\uFF44\uFF43\uFF52\uFF4F\uFF53\uFF53.org" => "redcross.org" # full-width letters
    }.each do |host, imitated|
      assert_equal imitated, @lookalike.imitated_domain(host), host
      assert_not @lookalike.known?(host), host
    end
  end

  test "an international host that imitates no issuer is not a lookalike" do
    %w[xn--mnchen-3ya.de m\u00FCnchen-schulung.de].each do |host|
      assert_nil @lookalike.imitated_domain(host), host
    end
  end

  test "suspicion: why a whole web address can't be trusted" do
    assert_equal Verification::Lookalike::Suspicion.new(host: "redcross-verify.com", looks_like: "redcross.org", disguised: false,
      lookalike_letters: false), @lookalike.suspicion("https://redcross-verify.com/c/1")
    assert_equal Verification::Lookalike::Suspicion.new(host: "verify-now.net", looks_like: nil, disguised: true,
      lookalike_letters: false), @lookalike.suspicion("https://www.redcross.org@verify-now.net/c/1")
    assert_equal Verification::Lookalike::Suspicion.new(host: "red\u0441ross.org", looks_like: "redcross.org", disguised: false,
      lookalike_letters: true), @lookalike.suspicion("https://www.red\u0441ross.org/c/1")

    [ nil, "TEST123", "https://www.redcross.org/x", "https://example.com/brochure", "https://m\u00FCnchen-schulung.de/" ].each do |text|
      assert_nil @lookalike.suspicion(text), text.inspect
    end
  end

  test "unrelated sites are not lookalikes" do
    %w[example.com https://example.com/brochure google.com usc.edu nyc.gov osha.gov bit.ly
       hearthstone.com youtube.com docs.google.com safety.com training.com].each do |host|
      assert_nil @lookalike.imitated_domain(host), host
      assert_not @lookalike.known?(host), host
    end
  end

  test "generic short names aren't tokens: heart, nsc and nccco inside a longer host are fine" do
    %w[hearthealth.com nscsports.com heartland-safety.com].each do |host|
      assert_nil @lookalike.imitated_domain(host), host
    end
  end

  test "text that isn't a web address is neither known nor a lookalike" do
    [ nil, "", "TEST123", "Juan Ortiz OSHA 10" ].each do |text|
      assert_nil @lookalike.imitated_domain(text), text.inspect
      assert_not @lookalike.known?(text), text.inspect
    end
  end

  test "for_issuers knows every issuer's domains, inactive ones included" do
    seed_issuers
    issuer("FOA").update!(active: false)

    lookalike = Verification::Lookalike.for_issuers

    assert lookalike.known?("thefoa.org")
    assert_nil lookalike.imitated_domain("bcert.me")
    assert_equal "redcross.org", lookalike.imitated_domain("redcross-verify.com")
  end
end
