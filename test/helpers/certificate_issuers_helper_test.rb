require "test_helper"

class CertificateIssuersHelperTest < ActionView::TestCase
  include ImportsHelper # import_picker_options, which views get from every helper

  setup do
    @summit = CertificateIssuer.create!(name: "Summit Safety Training", code: "SUMMIT", position: 1)
    @ridge = CertificateIssuer.create!(name: "Ridgeline CPR", code: "RIDGELINE", position: 2)
    @retired = CertificateIssuer.create!(name: "Old Tower School", code: "OLDTOWER", active: false)
  end

  test "issuer_picker_options lists the issuers, then Other..." do
    html = issuer_picker_options(issuers: [ @summit, @ridge ], selected: @ridge.id.to_s)

    options = Nokogiri::HTML5.fragment(html).css("option")
    assert_equal [ "Summit Safety Training", "Ridgeline CPR", "Other…" ], options.map(&:text)
    assert_equal [ @summit.id.to_s, @ridge.id.to_s, "other" ], options.map { it["value"] }
    assert_equal [ @ridge.id.to_s ], options.select { it["selected"] }.map { it["value"] }
  end

  test "issuer_picker_options puts an inactive current issuer first and can select Other..." do
    html = issuer_picker_options(issuers: [ @summit ], selected: "other", current: @retired)

    options = Nokogiri::HTML5.fragment(html).css("option")
    assert_equal [ "Old Tower School (inactive)", "Summit Safety Training", "Other…" ], options.map(&:text)
    assert_equal [ "other" ], options.select { it["selected"] }.map { it["value"] }
  end

  test "issuer_picker_options shows suggestions first, like the review queue's pickers" do
    suggestions = [ { "id" => @ridge.id, "name" => "Ridgeline CPR", "similarity" => 0.58 } ]

    fragment = Nokogiri::HTML5.fragment(issuer_picker_options(issuers: [ @summit, @ridge ], selected: @ridge.id, suggestions: suggestions))

    assert_equal [ "Ridgeline CPR · 58% match" ], fragment.css("optgroup[label=Suggested] option").map(&:text)
    assert_equal [ "Summit Safety Training", "Ridgeline CPR" ], fragment.css("optgroup[label=All] option").map(&:text)
    assert_equal 1, fragment.css("option[selected]").size
    assert_equal "Other…", fragment.css("option").last.text
  end

  test "issuer names are escaped" do
    @summit.update!(name: "<script>x</script>")

    assert_not_includes issuer_picker_options(issuers: [ @summit ], selected: nil), "<script>"
  end

  test "labels for methods and checks" do
    assert_equal "QR code or code lookup", certificate_issuer_method_label(CertificateIssuer.new(verification_method: :qr_or_code))
    assert_equal "No public registry", certificate_issuer_method_label("no_registry")
    assert_equal CertificateIssuer.verification_methods.keys.sort, CertificateIssuersHelper::METHOD_LABELS.keys.sort

    assert_equal "A person checks", certificate_issuer_check_label(@summit)
    assert_equal "OSHA Card Portal lookup", certificate_issuer_check_label(CertificateIssuer.new(automatic_check: "osha_card_portal"))
    assert_equal Verification::Checkers::KEYS, certificate_issuer_check_options.map(&:last)
    assert_equal Verification::Checkers::KEYS.sort, CertificateIssuersHelper::CHECK_LABELS.keys.sort
  end

  test "certificate_issuer_needs_details? is an issuer added with Other... and not filled in" do
    assert certificate_issuer_needs_details?(CertificateIssuer.new(name: "Typed"))
    assert_not certificate_issuer_needs_details?(CertificateIssuer.new(verification_method: :contact))
    assert_not certificate_issuer_needs_details?(CertificateIssuer.new(domains: [ "typed.example.com" ]))
  end
end
