require "test_helper"

class Imports::PersonMatcherTest < ActiveSupport::TestCase
  def match(name)
    Imports::PersonMatcher.new(name).call
  end

  def ids(result)
    result.suggestions.map { _1["id"] }
  end

  test "an exact normalized name is a match" do
    [ "Juan Ortiz", "Juan A. Ortiz", "ORTIZ, JUAN A", "  juan   ortiz ", "Ortiz, Juan" ].each do |name|
      result = match(name)

      assert_equal :matched, result.match, name
      assert_equal crew_members(:juan_ortiz), result.crew_member, name
      assert_equal({ "id" => crew_members(:juan_ortiz).id, "name" => "Juan Ortiz", "similarity" => 1.0 }, result.suggestions.first, name)
    end
  end

  test "aliases, preferred names, accents and punctuation match exactly" do
    assert_equal crew_members(:juan_ortiz), match("Jon Ortiz").crew_member
    assert_equal :matched, match("JUAN ORTIZ-RUIZ").match
    assert_equal crew_members(:maria_garcia), match("Maria Garcia-Lopez").crew_member # alias "María García-López"
    assert_equal :matched, match("García, María").match
    assert_equal crew_members(:maria_garcia), match("Mari Garcia").crew_member
    assert_equal crew_members(:dave_miller), match("Dave Miller").crew_member
  end

  test "two active exact matches are ambiguous: suggested, listing both" do
    twin = CrewMember.create!(first_name: "Juan", last_name: "Ortiz", employer: "Skyline Tower Services")

    result = match("Juan A. Ortiz")

    assert_equal :suggested, result.match
    assert_equal crew_members(:juan_ortiz), result.crew_member
    assert_equal [ crew_members(:juan_ortiz).id, twin.id ], ids(result).first(2)
    assert_equal [ 1.0, 1.0 ], result.suggestions.first(2).map { _1["similarity"] }
  end

  test "an inactive exact match is only a suggestion, with a note" do
    result = match("Sam Price")

    assert_equal :suggested, result.match
    assert_equal crew_members(:sam_inactive), result.crew_member
    assert_equal "inactive crew member", result.suggestions.first["note"]
  end

  test "an inactive namesake makes an exact match ambiguous; the active member is the top suggestion" do
    former = CrewMember.create!(first_name: "Li", last_name: "Chen", active: false)

    result = match("LI CHEN")

    assert_equal :suggested, result.match
    assert_equal crew_members(:li_chen), result.crew_member
    assert_equal [ crew_members(:li_chen).id, former.id ], ids(result).first(2)
    assert_equal [ nil, "inactive crew member" ], result.suggestions.first(2).map { _1["note"] }
  end

  test "a middle name on one side only still matches: same first and last name, words in order" do
    shamel = CrewMember.create!(first_name: "Shamel", last_name: "Deshawn Ferebee") # created from a card with the middle name

    [ "Shamel Ferebee", "FEREBEE, SHAMEL", "Shamel D. Ferebee" ].each do |name|
      result = match(name)

      assert_equal :matched, result.match, name
      assert_equal shamel, result.crew_member, name
      assert_equal 1.0, result.suggestions.first["similarity"], name
    end

    short = CrewMember.create!(first_name: "Tavon", last_name: "Rice")
    assert_equal [ :matched, short ], match("Tavon Marquis Rice").then { [ _1.match, _1.crew_member ] }
  end

  test "a middle name never joins different first or last names, or words out of order" do
    CrewMember.create!(first_name: "Shamel", last_name: "Deshawn Ferebee")

    [ "Deshawn Ferebee", "Shamel Deshawn", "Shamel Ferebee Deshawn", "Ferebee" ].each do |name|
      assert_not_equal :matched, match(name).match, name
    end
  end

  test "two members a short name fits are ambiguous: suggested, listing both" do
    one = CrewMember.create!(first_name: "Shamel", last_name: "Deshawn Ferebee")
    two = CrewMember.create!(first_name: "Shamel", last_name: "Andre Ferebee")

    result = match("Shamel Ferebee")

    assert_equal :suggested, result.match
    assert_equal [ one.id, two.id ].sort, ids(result).first(2).sort
  end

  test "an exact name beats one that only differs by a middle name" do
    long = CrewMember.create!(first_name: "Shamel", last_name: "Deshawn Ferebee")
    exact = CrewMember.create!(first_name: "Shamel", last_name: "Ferebee")

    assert_equal [ :matched, exact ], match("Shamel Ferebee").then { [ _1.match, _1.crew_member ] }
    assert_equal [ :matched, long ], match("Shamel Deshawn Ferebee").then { [ _1.match, _1.crew_member ] }
  end

  test "a one-letter slip in a long enough word matches, noted" do
    [ "Juan Ortez", "JUAN ORTZ", "Jaun Ortiz" ].each do |name|
      result = match(name)

      assert_equal [ :matched, crew_members(:juan_ortiz), :close_spelling ], [ result.match, result.crew_member, result.basis ], name
      assert_equal Imports::PersonMatcher::CLOSE_NOTE, result.suggestions.first["note"], name
    end
    assert_not_equal :matched, match("Li Chan").match # Chen and Chan are both surnames
  end

  test "two members a slip fits equally are ambiguous" do
    CrewMember.create!(first_name: "Juan", last_name: "Ortaz")

    result = match("Juan Ortez")

    assert_equal [ :suggested, :close_spelling ], [ result.match, result.basis ]
  end

  test "basis says which rule matched" do
    CrewMember.create!(first_name: "Shamel", last_name: "Deshawn Ferebee")

    assert_equal :exact, match("Juan Ortiz").basis
    assert_equal :middle_name, match("Shamel Ferebee").basis
    assert_equal :none, match("Nobody Atall").basis
    assert_equal :none, match("").basis
  end

  test "a misspelling that clearly beats everyone else is suggested" do
    result = match("Juan Ortizes") # two letters off: not a close spelling

    assert_equal :suggested, result.match
    assert_equal crew_members(:juan_ortiz), result.crew_member
    assert_operator result.suggestions.first["similarity"], :>=, 0.6
  end

  test "a close runner-up blocks the suggestion (margin rule)" do
    CrewMember.create!(first_name: "Juan", last_name: "Ortizzas") # both two letters off "Ortizes"

    result = match("Juan Ortizes")
    best, second = result.suggestions.first(2).map { _1["similarity"] }

    assert_operator best - second, :<, 0.15
    assert_equal :unmatched, result.match
    assert_nil result.crew_member
    assert_includes ids(result), crew_members(:juan_ortiz).id
  end

  test "the margin and threshold are compared exactly as configured" do
    Imports::Config.with(person_margin: 0.0) do
      CrewMember.create!(first_name: "Juan", last_name: "Ortizzas")
      assert_equal :suggested, match("Juan Ortizes").match
    end

    Imports::Config.with(person_suggest_threshold: 0.99) do
      assert_equal :unmatched, match("Juan Ortizes").match
    end
  end

  test "a margin of exactly 0.15 passes despite float rounding" do
    matcher = Imports::PersonMatcher.new("anyone")

    assert matcher.send(:clear_winner?, 0.75, 0.6)
    assert matcher.send(:clear_winner?, 0.7, 0.55)
    assert matcher.send(:clear_winner?, 0.6, nil)
    assert_not matcher.send(:clear_winner?, 0.74, 0.6)
    assert_not matcher.send(:clear_winner?, 0.59, nil)
  end

  test "below the threshold is unmatched but still lists candidates to pick from" do
    result = match("Jaun Ortis") # ~0.3 against "juan ortiz"

    assert_equal :unmatched, result.match
    assert_nil result.crew_member
    assert_equal crew_members(:juan_ortiz).id, ids(result).first
    assert_operator result.suggestions.first["similarity"], :<, 0.6
  end

  test "nobody close is unmatched with no suggestions" do
    result = match("Xavier Quentin-Wolfe")

    assert_equal :unmatched, result.match
    assert_empty result.suggestions
  end

  test "an inactive member can be a fuzzy suggestion and is flagged" do
    result = match("Sam Pryce")

    assert_equal crew_members(:sam_inactive).id, ids(result).first
    assert_equal "inactive crew member", result.suggestions.first["note"]
  end

  test "a bare surname is never an exact match" do
    result = match("ORTIZ")

    assert_not_equal :matched, result.match
  end

  test "blank names are unmatched" do
    [ nil, "", "  ", "---" ].each do |name|
      result = match(name)

      assert_equal :unmatched, result.match
      assert_empty result.suggestions
    end
  end

  test "lists at most five suggestions, best first" do
    6.times { |i| CrewMember.create!(first_name: "Juan", last_name: "Ortiz#{"z" * (i + 1)}") }

    result = match("Juan Ortiz")
    assert_equal 5, result.suggestions.size
    assert_equal crew_members(:juan_ortiz).id, ids(result).first
    assert_equal result.suggestions.map { _1["similarity"] }.sort.reverse, result.suggestions.map { _1["similarity"] }
  end
end
