require "test_helper"

class Notifications::SendBudgetTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 2, 6, 0)
    @saved_limit = ENV.delete("MAIL_DAILY_LIMIT")
  end

  teardown { @saved_limit.nil? ? ENV.delete("MAIL_DAILY_LIMIT") : ENV["MAIL_DAILY_LIMIT"] = @saved_limit }

  test "the daily limit is MAIL_DAILY_LIMIT, 1,000 by default, ignoring junk, zero and negatives" do
    assert_equal 1000, Notifications::SendBudget.daily_limit

    ENV["MAIL_DAILY_LIMIT"] = "250"
    assert_equal 250, Notifications::SendBudget.daily_limit

    [ "", "lots", "12.5", "0", "-5" ].each do |junk|
      ENV["MAIL_DAILY_LIMIT"] = junk
      assert_equal 1000, Notifications::SendBudget.daily_limit, "MAIL_DAILY_LIMIT=#{junk.inspect}"
    end
  end

  test "reserve! allows MAIL_DAILY_LIMIT sends a day, then refuses" do
    ENV["MAIL_DAILY_LIMIT"] = "5"
    5.times { assert Notifications::SendBudget.reserve! }

    assert_not Notifications::SendBudget.reserve!
    assert_equal 5, Notifications::SendBudget.sent_today
    assert_equal 0, Notifications::SendBudget.remaining_today
  end

  test "without MAIL_DAILY_LIMIT reserve! stops at 1,000 a day" do
    Notifications::SendBudget.record!(999)

    assert Notifications::SendBudget.reserve!
    assert_not Notifications::SendBudget.reserve!
    assert_equal 1000, Notifications::SendBudget.sent_today
  end

  test "a limit lowered below today's sends refuses the rest of the day" do
    Notifications::SendBudget.record!(40)
    ENV["MAIL_DAILY_LIMIT"] = "30"

    assert_not Notifications::SendBudget.reserve!
    assert_equal 0, Notifications::SendBudget.remaining_today
  end

  test "remaining_today counts down from the daily limit" do
    assert_equal 1000, Notifications::SendBudget.remaining_today

    3.times { Notifications::SendBudget.reserve! }
    assert_equal 3, Notifications::SendBudget.sent_today
    assert_equal 997, Notifications::SendBudget.remaining_today
  end

  test "record! counts unreserved sends against the cap and never goes negative" do
    ENV["MAIL_DAILY_LIMIT"] = "90"
    Notifications::SendBudget.record!(89)
    assert Notifications::SendBudget.reserve!
    assert_not Notifications::SendBudget.reserve!

    Notifications::SendBudget.record!
    assert_equal 91, Notifications::SendBudget.sent_today
    assert_equal 0, Notifications::SendBudget.remaining_today
  end

  test "release! hands an unused reservation back" do
    Notifications::SendBudget.reserve!
    Notifications::SendBudget.release!

    assert_equal 0, Notifications::SendBudget.sent_today
  end

  test "the budget resets at midnight Denver time" do
    travel_to Time.zone.local(2026, 11, 2, 23, 59)
    Notifications::SendBudget.record!(Notifications::SendBudget.daily_limit)
    assert_not Notifications::SendBudget.reserve!

    travel_to Time.zone.local(2026, 11, 3, 0, 1)
    assert Notifications::SendBudget.reserve!
    assert_equal 1, Notifications::SendBudget.sent_today
  end

  test "mark_deferred! and deferred_on?" do
    assert_not Notifications::SendBudget.deferred_on?(Date.current)

    Notifications::SendBudget.mark_deferred!
    Notifications::SendBudget.mark_deferred!(2)

    assert Notifications::SendBudget.deferred_on?(Date.current)
    assert_not Notifications::SendBudget.deferred_on?(Date.yesterday)
    assert_equal 3, EmailSendDay.deferred_on(Date.current)
  end

  test "recent_deferral returns today's or yesterday's deferral, today first" do
    assert_nil Notifications::SendBudget.recent_deferral

    EmailSendDay.create!(day: Date.current - 2, deferred_count: 9)
    assert_nil Notifications::SendBudget.recent_deferral

    yesterday = EmailSendDay.create!(day: Date.yesterday, sent_count: 1000, deferred_count: 4)
    assert_equal yesterday, Notifications::SendBudget.recent_deferral

    today = EmailSendDay.create!(day: Date.current, sent_count: 1000, deferred_count: 1)
    assert_equal today, Notifications::SendBudget.recent_deferral
  end

  test "recent_deferral ignores days that only sent" do
    EmailSendDay.create!(day: Date.current, sent_count: 40)

    assert_nil Notifications::SendBudget.recent_deferral
  end
end
