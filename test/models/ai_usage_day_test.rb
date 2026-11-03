require "test_helper"

class AiUsageDayTest < ActiveSupport::TestCase
  test "record! creates the day's row" do
    day = Date.new(2026, 1, 5)
    AiUsageDay.record!(provider: :anthropic, units: 500, day: day)
    row = AiUsageDay.find_by!(day: day, provider: "anthropic")
    assert_equal [ 500, 1 ], [ row.units_used, row.requests ]
  end

  test "record! increments an existing row atomically" do
    row = ai_usage_days(:workers_ai_today)
    travel 1.minute do
      AiUsageDay.record!(provider: "workers_ai", units: 300)
      AiUsageDay.record!(provider: "workers_ai", units: 50, requests: 2)
    end
    row.reload
    assert_equal 1550, row.units_used
    assert_equal 11, row.requests
    assert_operator row.updated_at, :>, row.created_at
  end

  test "record! defaults to Denver's date" do
    travel_to Time.utc(2026, 11, 3, 3, 0) do # Nov 2 in Denver
      AiUsageDay.record!(provider: "ollama", units: 1)
      assert AiUsageDay.exists?(day: Date.new(2026, 11, 2), provider: "ollama")
    end
  end

  test "used_on" do
    assert_equal 1200, AiUsageDay.used_on(Date.current, "workers_ai")
    assert_equal 8800, AiUsageDay.used_on(Date.current - 1, :workers_ai)
    assert_equal 0, AiUsageDay.used_on(Date.current, "anthropic")
  end

  test "one row per day and provider" do
    duplicate = AiUsageDay.new(day: Date.current, provider: "workers_ai")
    assert_not duplicate.valid?
    assert AiUsageDay.new(day: Date.current, provider: "anthropic").valid?
  end
end
