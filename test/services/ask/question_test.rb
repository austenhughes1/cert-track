require "test_helper"

class Ask::QuestionTest < ActiveSupport::TestCase
  test "tokens are lowercased, transliterated and stripped of possessives" do
    assert_equal %w[does jose ortiz have juan osha 30], Ask::Question.new("Does José Ortiz have Juan’s OSHA-30?").words
    assert_equal %w[chris flagger], Ask::Question.new("Chris' flagger").words
    assert_equal %w[obrien certs], Ask::Question.new("O'Brien's certs").words
    assert_equal %w[doesnt juan have it], Ask::Question.new("Doesn't Juan have it?").words
  end

  test "letters and digits are split and number words become digits" do
    assert_equal %w[osha 30], Ask::Question.new("osha30").words
    assert_equal %w[osha 10 in 60 days], Ask::Question.new("OSHA ten in sixty days").words
  end

  test "compound number words become one number that keeps its text" do
    question = Ask::Question.new("expiring in forty-five days or seventy two hours")

    assert_equal %w[expiring in 45 days or 72 hours], question.words
    assert_equal "forty-five", question.phrase(2..2)
    assert_equal "seventy two", question.phrase(5..5)
    assert_equal %w[40 5], Ask::Question.new("forty, five").words
    assert_equal %w[13 80], Ask::Question.new("thirteen eighty").words
  end

  test "phrase returns the original text without a possessive" do
    question = Ask::Question.new("Is  Jaun   Ortis's flagger current?")

    assert_equal "Is Jaun Ortis's flagger current?", question.text
    assert_equal "Jaun Ortis", question.phrase(1..2)
  end

  test "substitute swaps the words and keeps the possessive" do
    question = Ask::Question.new("Is Jaun's flagger current?")

    assert_equal "Is Juan Ortiz's flagger current?", question.substitute(1..1, "Juan Ortiz")
  end

  test "keyword flags" do
    assert Ask::Question.new("Who has flagger?").who?
    assert Ask::Question.new("which crew have flagger").who?
    assert_not Ask::Question.new("which flagger is current").who?
    assert Ask::Question.new("does juan have it").check?
    assert Ask::Question.new("anything expiring soon").expiring?
    assert Ask::Question.new("renewals due").expiring?
    assert Ask::Question.new("is 2417 compliant").gaps?
    assert Ask::Question.new("who's missing on the job").project_context?
    assert Ask::Question.new("When does it expire").asks_when?
    assert_not Ask::Question.new("does it expire").asks_when?
  end

  test "expired, negated and need flags" do
    assert Ask::Question.new("Has Li's first aid expired?").expired?
    assert Ask::Question.new("did anything lapse").expired?
    assert Ask::Question.new("what's past due").expired?
    assert_not Ask::Question.new("what expires soon").expired?

    assert Ask::Question.new("Who doesn't have flagger?").negated?
    assert Ask::Question.new("who does not hold flagger").negated?
    assert Ask::Question.new("who has no flagger").negated?
    assert Ask::Question.new("anyone without a CDL").negated?
    assert_not Ask::Question.new("who has flagger").negated?
    assert_not Ask::Question.new("isn't Juan's flagger current").negated?

    assert Ask::Question.new("who needs flagger on 2417").gaps?
    assert Ask::Question.new("what is required on 2417").gaps?
    assert_not Ask::Question.new("I need to know who has flagger").gaps?
  end

  test "normalize gives the comparable form of a name" do
    assert_equal "first aid cpr aed", Ask::Question.normalize("First Aid/CPR/AED")
    assert_equal "osha 30 hour", Ask::Question.normalize("OSHA 30-Hour")
  end

  test "blank and overlong text" do
    assert Ask::Question.new("  ?! ").blank?
    assert_equal Ask::Question::MAX_LENGTH, Ask::Question.new("a" * 1000).text.length
  end
end
