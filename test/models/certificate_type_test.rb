require "test_helper"

class CertificateTypeTest < ActiveSupport::TestCase
  def build(**attrs)
    CertificateType.new({ name: "Rigger", code: "RIGGER" }.merge(attrs))
  end

  test "requires name and code" do
    type = CertificateType.new
    assert_not type.valid?
    assert_includes type.errors[:name], "can't be blank"
    assert_includes type.errors[:code], "can't be blank"
  end

  test "name and code are unique case-insensitively" do
    assert_not build(name: "flagger").valid?
    assert_not build(code: "flagger").valid?
  end

  test "normalizes code, name and aliases" do
    type = CertificateType.create!(name: "  Rigger   and Signal ", code: " rig-1 ", aliases: [ " Rigger ", "rigger", "", " Signal Person " ])
    assert_equal "RIG-1", type.code
    assert_equal "Rigger and Signal", type.name
    assert_equal [ "Rigger", "Signal Person" ], type.aliases
  end

  test "code format and validity months" do
    assert_not build(code: "OSHA 30").valid?
    assert_not build(validity_months: 0).valid?
    assert_not build(validity_months: 1.5).valid?
    assert build(validity_months: nil).valid?
    assert build(validity_months: 12).valid?
  end

  test "active and ordered scopes" do
    assert_not_includes CertificateType.active, certificate_types(:retired_hazwoper)
    assert_equal %w[OSHA30 FLAGGER FIRSTAID CLIMBER CDLA HAZWOPER40], CertificateType.ordered.pluck(:code)
    CertificateType.create!(name: "Aaa Unpositioned", code: "AAA")
    assert_equal "AAA", CertificateType.ordered.last.code
  end

  test "find_by_code ignores case and whitespace" do
    assert_equal certificate_types(:osha30), CertificateType.find_by_code(" osha30 ")
    assert_nil CertificateType.find_by_code("NOPE")
    assert_nil CertificateType.find_by_code(nil)
  end

  test "fuzzy_match scores names and aliases" do
    matches = CertificateType.fuzzy_match("OSHA 30-Hour Construction Industry Outreach Training")
    type, similarity = matches.first
    assert_equal certificate_types(:osha30), type
    assert_in_delta 1.0, similarity, 0.001

    type, similarity = CertificateType.fuzzy_match("Flagger Certificate").first
    assert_equal certificate_types(:flagger), type
    assert_operator similarity, :>=, 0.45
  end

  test "fuzzy_match respects threshold, scope and blank input" do
    assert_empty CertificateType.fuzzy_match("Completely unrelated words")
    assert_empty CertificateType.fuzzy_match("")
    assert CertificateType.fuzzy_match("HAZWOPER 40").any? { |type, _| type == certificate_types(:retired_hazwoper) }
    assert_empty CertificateType.active.fuzzy_match("HAZWOPER 40")
    assert_operator CertificateType.fuzzy_match("first aid", threshold: 0.1).size, :>=, 1
  end

  test "fuzzy_match is safe with quotes and placeholders" do
    assert_empty CertificateType.fuzzy_match("x' OR 1=1 -- ? :query")
  end

  test "expiry_for and never_expires?" do
    assert certificate_types(:osha30).never_expires?
    assert_nil certificate_types(:osha30).expiry_for(Date.new(2025, 3, 14))
    assert_equal Date.new(2028, 3, 14), certificate_types(:flagger).expiry_for(Date.new(2025, 3, 14))
    assert_nil certificate_types(:flagger).expiry_for(nil)
  end

  test "an invalid validity change leaves certificates alone" do
    cert = certificates(:juan_flagger)

    assert_not certificate_types(:flagger).update(validity_months: 0)
    assert_equal cert.expires_on, cert.reload.expires_on
  end

  test "cannot be destroyed while used" do
    assert_not certificate_types(:flagger).destroy
    assert CertificateType.create!(name: "Unused", code: "UNUSED").destroy
  end
end
