require "test_helper"

class Ask::ParserTest < ActiveSupport::TestCase
  def parse(text, pins: {})
    Ask::Parser.new(Ask::Question.new(text), today: Date.current, pins: pins).call
  end

  test "each match claims its own words; the rest are leftovers" do
    result = parse("Does Juan Ortiz have OSHA 30 by any chance?")

    assert_equal crew_members(:juan_ortiz), result.person.record
    assert_equal 1..2, result.person.range
    assert_equal certificate_types(:osha30), result.type.record
    assert_equal 4..5, result.type.range
    assert_equal [ "chance" ], result.leftover_phrases
  end

  test "a number beside a type word must be one of the type's numbers" do
    result = parse("does juan have osha 10")

    assert_nil result.type
    assert_equal [ "osha 10" ], result.leftover_phrases
    assert_equal [ certificate_types(:osha30) ], result.type_matcher.suggestions
  end

  test "fuzzy type scores ignore stopwords such as certification" do
    assert_nil parse("does juan have scuba certification").type
    assert_equal certificate_types(:flagger), parse("does juan have flagger certification").type.record
  end

  test "codes match with spaces and punctuation removed" do
    %w[OSHA30 osha-30 Osha\ 30 FIRST-AID cdl\ a].zip(%i[osha30 osha30 osha30 first_aid cdl_a]).each do |text, type|
      assert_equal certificate_types(type), parse("who has #{text}").type&.record, text
    end
  end

  test "a project code takes its neighbouring name words, so 'tower' isn't the Tower Climber alias" do
    result = parse("what's missing on tower 2417")

    assert_equal projects(:tower_2417), result.project.record
    assert_equal 3..4, result.project.range
    assert_nil result.type
  end

  test "a type and a project in one question" do
    result = parse("who has tower climber on 2417")

    assert_equal projects(:tower_2417), result.project.record
    assert_equal certificate_types(:climber), result.type.record
  end

  test "project names match only when the question is about compliance or expiry" do
    assert_equal projects(:tower_2417), parse("what's missing on tower upgrade").project&.record
    assert_nil parse("does juan have tower upgrade").project
  end

  test "short codes need three characters" do
    Project.create!(name: "Yard", code: "Y1")

    assert_nil parse("what's missing on y1").project
  end

  test "an exact person keeps words a fuzzy type also wanted" do
    CertificateType.create!(name: "Fall Protection", code: "FALLPRO")
    fallon = CrewMember.create!(first_name: "Rich", last_name: "Fallon")

    result = parse("does rich fallon have flagger")
    assert_equal fallon, result.person.record
    assert_equal certificate_types(:flagger), result.type.record

    result = parse("does fallon have fall protection")
    assert_equal fallon, result.person.record
    assert_equal "FALLPRO", result.type.record.code
  end

  test "accents, middle initials and aliases match exactly" do
    jose = CrewMember.create!(first_name: "José", last_name: "Núñez")

    assert_equal jose, parse("does jose nunez have flagger").person.record
    assert_not parse("does jose nunez have flagger").person.fuzzy
    assert_equal crew_members(:juan_ortiz), parse("does Juan A. Ortiz have flagger").person.record
    assert_equal crew_members(:maria_garcia), parse("María García-López's certs").person.record
  end

  test "a single word must be close to a name word" do
    assert_equal crew_members(:juan_ortiz), parse("does ortis have flagger").person&.record
    assert_nil parse("does zorro have flagger").person
  end

  test "pins replace what the text matched and keep its range" do
    result = parse("Does Juan have flagger?", pins: { crew_member_id: crew_members(:li_chen).id })

    assert_equal crew_members(:li_chen), result.person.record
    assert_equal 1..1, result.person.range
    assert result.person.matched?
  end

  test "a time window claims its words" do
    result = parse("what expires in the next 60 days")

    assert_equal Date.current + 60, result.window.to
    assert_empty result.leftovers
  end
end
