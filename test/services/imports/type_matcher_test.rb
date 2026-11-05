require "test_helper"

class Imports::TypeMatcherTest < ActiveSupport::TestCase
  test "a provider's wording of a type's name finds it, and a number in the name has to agree" do
    ten = CertificateType.create!(name: "OSHA 10 Test", code: "T10", aliases: [ "OSHA 10-Hour Construction Safety and Health" ])
    thirty = CertificateType.create!(name: "OSHA 30 Test", code: "T30", aliases: [ "OSHA 30-Hour Construction Safety and Health" ])
    blood = CertificateType.create!(name: "Bloodborne Pathogens", code: "BBPTEST")

    assert_equal blood, by_printed_name("Bloodborne Pathogens Online Training").type
    assert_equal blood, by_printed_name("OSHA Bloodborne Pathogens Training Multi-Industry").type
    assert_equal thirty, by_printed_name("30-hour Construction Safety and Health").type
    assert_equal ten, by_printed_name("10-hour Construction Safety and Health").type
    assert_not_includes by_printed_name("30-hour Construction Safety and Health").suggestions.map { it["id"] }, ten.id
  end

  def by_printed_name(name)
    Imports::TypeMatcher.new(code: nil, name_as_printed: name).call
  end

  def match(code: nil, name: nil)
    Imports::TypeMatcher.new(code:, name_as_printed: name).call
  end

  test "a code on the certificate types is a match, case and whitespace insensitive" do
    result = match(code: " osha30 ", name: "OSHA 30-Hour Construction Industry Outreach Training")

    assert_equal :matched, result.match
    assert_equal certificate_types(:osha30), result.type
    assert_equal({ "id" => certificate_types(:osha30).id, "name" => "OSHA 30 Construction", "similarity" => 1.0 }, result.suggestions.first)
    assert_equal 1, result.suggestions.count { |suggestion| suggestion["id"] == certificate_types(:osha30).id }
  end

  test "the code wins over the printed name" do
    result = match(code: "FLAGGER", name: "Adult First Aid CPR AED")

    assert_equal :matched, result.match
    assert_equal certificate_types(:flagger), result.type
    assert_equal [ certificate_types(:flagger).id, certificate_types(:first_aid).id ], result.suggestions.map { _1["id"] }
  end

  test "an unknown code falls back to the printed name, which is only a suggestion" do
    result = match(code: "OSHA-30", name: "Traffic Control Flagger")

    assert_equal :suggested, result.match
    assert_equal certificate_types(:flagger), result.type
    assert_equal 1.0, result.suggestions.first["similarity"]
  end

  test "an exact printed name or alias without a code is still only a suggestion" do
    result = match(name: "OSHA 30 Construction")

    assert_equal :suggested, result.match
    assert_equal certificate_types(:osha30), result.type
  end

  test "a misspelled name above the threshold is suggested, best first" do
    result = match(name: "Tower Climer")

    assert_equal :suggested, result.match
    assert_equal certificate_types(:climber), result.type
    assert_operator result.suggestions.first["similarity"], :>=, 0.45
    assert_equal result.suggestions.map { _1["similarity"] }.sort.reverse, result.suggestions.map { _1["similarity"] }
  end

  test "below the threshold is unmatched with no suggestions" do
    result = match(name: "Rigger and Signal Person")

    assert_equal :unmatched, result.match
    assert_nil result.type
    assert_empty result.suggestions
  end

  test "the threshold comes from Imports::Config" do
    Imports::Config.with(type_suggest_threshold: 0.99) do
      assert_equal :unmatched, match(name: "Tower Climer").match
    end
  end

  test "blank input is unmatched" do
    assert_equal :unmatched, match.match
    assert_equal :unmatched, match(code: "  ", name: " ").match
  end

  test "an inactive type's code is a suggestion with a note, after active candidates" do
    result = match(code: "hazwoper40", name: "HAZWOPER 40 Hour")

    assert_equal :suggested, result.match
    assert_equal certificate_types(:retired_hazwoper), result.type
    assert_equal({ "id" => certificate_types(:retired_hazwoper).id, "name" => "HAZWOPER 40", "similarity" => 1.0,
                   "note" => "inactive certificate type" }, result.suggestions.last)

    with_active_candidate = match(code: "HAZWOPER40", name: "Authorized Climber")
    assert_equal certificate_types(:climber), with_active_candidate.type
    assert_equal [ certificate_types(:climber).id, certificate_types(:retired_hazwoper).id ], with_active_candidate.suggestions.map { _1["id"] }
  end

  test "inactive types are never fuzzy candidates" do
    result = match(name: "HAZWOPER 40")

    assert_equal :unmatched, result.match
  end

  test "lists at most five suggestions" do
    6.times { |i| CertificateType.create!(name: "Aerial Lift Operator Level #{i}", code: "LIFT#{i}") }

    result = match(name: "Aerial Lift Operator Level")
    assert_equal 5, result.suggestions.size
    assert_equal :suggested, result.match
  end
end
