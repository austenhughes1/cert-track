require "test_helper"

class Ask::TimeWindowTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 11, 3)

  def parse(text)
    Ask::TimeWindow.parse(Ask::Question.new(text), today: TODAY)
  end

  test "defaults to the next 30 days and claims no words" do
    window, indexes = parse("what is expiring soon")

    assert_equal TODAY..(TODAY + 30), window.range
    assert_equal "in the next 30 days", window.label
    assert_not window.explicit
    assert_empty indexes
  end

  test "a number and a unit, with the words before them" do
    window, indexes = parse("what expires in the next 60 days")
    assert_equal TODAY + 60, window.to
    assert_equal "in the next 60 days", window.label
    assert_equal [ 2, 3, 4, 5, 6 ], indexes

    assert_equal TODAY + 14, parse("next 2 weeks").first.to
    assert_equal TODAY.advance(months: 3), parse("within three months").first.to
    assert_equal TODAY.advance(years: 1), parse("in 1 year").first.to
    assert_equal "in the next week", parse("in 1 week").first.label
  end

  test "next and this with a unit" do
    assert_equal TODAY + 7, parse("next week").first.to
    assert_equal TODAY.advance(months: 1), parse("expiring next month").first.to
    assert_equal Date.new(2026, 11, 30), parse("this month").first.to
    assert_equal "this month", parse("this month").first.label
    assert_equal TODAY.end_of_week, parse("this week").first.to
    assert_equal Date.new(2026, 12, 31), parse("this year").first.to
  end

  test "today and tomorrow" do
    assert_equal TODAY..TODAY, parse("what expires today").first.range
    assert_equal TODAY + 1, parse("tomorrow").first.to
  end

  test "a or an before a singular unit is one of it" do
    window, indexes = parse("what expires in a week")
    assert_equal TODAY + 7, window.to
    assert_equal "in the next week", window.label
    assert_equal [ 2, 3, 4 ], indexes

    assert_equal TODAY.advance(years: 1), parse("within a year").first.to
    assert_equal TODAY.advance(months: 1), parse("in a month").first.to
    assert_not parse("what is a day").first.explicit, "needs in/within/over before it"
    assert_not parse("in a weeks").first.explicit
  end

  test "number words, compound ones too" do
    assert_equal TODAY + 45, parse("in forty-five days").first.to
    assert_equal TODAY + 21, parse("within twenty one days").first.to
    assert_equal "in the next 45 days", parse("in forty-five days").first.label
  end

  test "past windows run up to yesterday" do
    window, indexes = parse("what expired in the last 60 days")
    assert_equal (TODAY - 60)..(TODAY - 1), window.range
    assert_equal "in the last 60 days", window.label
    assert window.past
    assert window.explicit
    assert_equal [ 2, 3, 4, 5, 6 ], indexes

    assert_equal TODAY.advance(months: -1), parse("what expired last month").first.from
    assert_equal TODAY - 14, parse("over the past 2 weeks").first.from
    assert_equal TODAY.advance(years: -1), parse("in the past year").first.from
    assert_equal "in the last 30 days", parse("what lapsed recently").first.label
    assert_equal (TODAY - 1)..(TODAY - 1), parse("yesterday").first.range
    assert_not parse("next week").first.past
    assert_not parse("Juan's last flagger").first.explicit
  end

  test "huge numbers are capped" do
    assert_equal TODAY + Ask::TimeWindow::MAX_DAYS, parse("in 99999999 days").first.to
  end
end
