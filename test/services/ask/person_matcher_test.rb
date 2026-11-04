require "test_helper"

class Ask::PersonMatcherTest < ActiveSupport::TestCase
  setup do
    @will = CrewMember.create!(first_name: "Will", last_name: "Turner")
    @may = CrewMember.create!(first_name: "May", last_name: "Lopez")
  end

  def matched(text)
    question = Ask::Question.new(text)
    Ask::Match.pick(Ask::PersonMatcher.new(question).hits, question: question)&.record
  end

  test "Will and May are names where a name fits" do
    [ "Does Will have flagger?", "is will certified", "certs for Will", "what about will", "Will's certs", "Will Turner's certs",
      "What does Will Turner have?" ].each { |text| assert_equal @will, matched(text), text }
    [ "Is May certified for first aid?", "Has May got her flagger?", "May's certs", "May Lopez's certs" ]
      .each { |text| assert_equal @may, matched(text), text }
  end

  test "and verbs everywhere else" do
    juan = crew_members(:juan_ortiz)

    [ "Will Juan's flagger expire soon?", "When will Juan's flagger expire?", "Juan's flagger will expire soon" ]
      .each { |text| assert_equal juan, matched(text), text }
    [ "who will need flagger", "Will anyone need flagger?", "May I see who has CPR?", "What expires in May?", "it may lapse" ]
      .each { |text| assert_nil matched(text), text }
  end

  test "a lone Will must be an active member's exact name" do
    @will.update!(active: false)
    assert_nil matched("Does Will have flagger?")
    assert_equal @will, matched("Does Will Turner have flagger?")

    CrewMember.create!(first_name: "Willa", last_name: "Smith")
    assert_nil matched("Does Will have flagger?"), "no fuzzy match through a stopword"

    william = CrewMember.create!(first_name: "William", last_name: "Grant")
    assert_equal william, matched("Does Will have flagger?"), "a nickname is still an exact name"
  end

  test "a stopword name is never a near miss" do
    @will.destroy!
    CrewMember.create!(first_name: "Willa", last_name: "Smith")

    assert_empty Ask::PersonMatcher.new(Ask::Question.new("Does Will have flagger?")).suggestions
  end
end
