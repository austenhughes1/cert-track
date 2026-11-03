require "test_helper"

class EmailSendDayTest < ActiveSupport::TestCase
  setup { @day = Date.new(2026, 11, 2) }

  test "reserve! creates the day's row, then increments up to the limit and no further" do
    assert EmailSendDay.reserve!(day: @day, limit: 3)
    assert_equal 1, EmailSendDay.sent_on(@day)

    assert EmailSendDay.reserve!(day: @day, limit: 3)
    assert EmailSendDay.reserve!(day: @day, limit: 3)
    assert_not EmailSendDay.reserve!(day: @day, limit: 3)
    assert_not EmailSendDay.reserve!(day: @day, limit: 3)

    assert_equal 3, EmailSendDay.sent_on(@day)
    assert_equal 1, EmailSendDay.where(day: @day).count
  end

  test "reserve! keeps each day separate" do
    2.times { EmailSendDay.reserve!(day: @day, limit: 2) }

    assert_not EmailSendDay.reserve!(day: @day, limit: 2)
    assert EmailSendDay.reserve!(day: @day + 1, limit: 2)
  end

  test "reserve! refuses a non-positive limit without writing" do
    assert_not EmailSendDay.reserve!(day: @day, limit: 0)
    assert_not EmailSendDay.exists?(day: @day)
  end

  test "reserve! is never served from the query cache" do
    ActiveRecord::Base.cache do
      3.times { EmailSendDay.reserve!(day: @day, limit: 2) }
    end

    assert_equal 2, EmailSendDay.sent_on(@day)
  end

  test "record_sent! adds sends unconditionally, even past any limit" do
    EmailSendDay.record_sent!(day: @day, by: 95)
    EmailSendDay.record_sent!(day: @day)

    assert_equal 96, EmailSendDay.sent_on(@day)
    assert_not EmailSendDay.reserve!(day: @day, limit: 90)
  end

  test "release! gives sends back without going below zero" do
    EmailSendDay.record_sent!(day: @day, by: 2)

    EmailSendDay.release!(day: @day)
    assert_equal 1, EmailSendDay.sent_on(@day)

    EmailSendDay.release!(day: @day, by: 5)
    assert_equal 0, EmailSendDay.sent_on(@day)
  end

  test "release! on a day with no row is a no-op" do
    assert_nothing_raised { EmailSendDay.release!(day: @day) }
    assert_not EmailSendDay.exists?(day: @day)
  end

  test "record_deferred! counts deferrals separately from sends" do
    EmailSendDay.reserve!(day: @day, limit: 90)
    EmailSendDay.record_deferred!(day: @day, by: 4)
    EmailSendDay.record_deferred!(day: @day)

    assert_equal 5, EmailSendDay.deferred_on(@day)
    assert_equal 1, EmailSendDay.sent_on(@day)
  end

  test "sent_on and deferred_on are zero for a day with no row" do
    assert_equal 0, EmailSendDay.sent_on(@day)
    assert_equal 0, EmailSendDay.deferred_on(@day)
  end

  test "with_deferrals selects only days that deferred mail" do
    quiet = EmailSendDay.create!(day: @day, sent_count: 10)
    busy = EmailSendDay.create!(day: @day + 1, sent_count: 90, deferred_count: 3)

    assert_includes EmailSendDay.with_deferrals, busy
    assert_not_includes EmailSendDay.with_deferrals, quiet
  end

  test "validates day presence and uniqueness and non-negative counts" do
    EmailSendDay.create!(day: @day)

    assert_not EmailSendDay.new(day: nil).valid?
    assert_not EmailSendDay.new(day: @day).valid?
    assert_not EmailSendDay.new(day: @day + 1, sent_count: -1).valid?
    assert_not EmailSendDay.new(day: @day + 1, deferred_count: -1).valid?
    assert EmailSendDay.new(day: @day + 1).valid?
  end
end
