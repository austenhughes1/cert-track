require "test_helper"

class Ai::BudgetTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast".freeze

  setup do
    AiUsageDay.delete_all
  end

  test "next_reset_at is the next 00:05 UTC strictly after now" do
    assert_equal Time.utc(2026, 11, 4, 0, 5), Ai::Budget.next_reset_at(Time.utc(2026, 11, 3, 15, 30))
    assert_equal Time.utc(2026, 11, 3, 0, 5), Ai::Budget.next_reset_at(Time.utc(2026, 11, 3, 0, 1))
    assert_equal Time.utc(2026, 11, 4, 0, 5), Ai::Budget.next_reset_at(Time.utc(2026, 11, 3, 0, 5))
    assert_equal Time.utc(2027, 1, 1, 0, 5), Ai::Budget.next_reset_at(Time.utc(2026, 12, 31, 23, 59, 59))
  end

  test "next_reset_at works from Denver time, where the UTC day has already turned" do
    denver_evening = Time.find_zone("America/Denver").local(2026, 11, 3, 18, 30) # 01:30 UTC on Nov 4

    assert_equal Time.utc(2026, 11, 5, 0, 5), Ai::Budget.next_reset_at(denver_evening)
  end

  test "units are neurons from the per-model rates, rounded up" do
    neurons = Ai::Budget.units_for(provider: "workers_ai", model: MODEL, input_tokens: 2_000, output_tokens: 300)

    # 2,000 * 26,668 / 1M + 300 * 204,805 / 1M = 53.3 + 61.4
    assert_equal 115, neurons
  end

  test "images add the model's per-image estimate" do
    model = "@cf/meta/llama-3.2-11b-vision-instruct"
    without = Ai::Budget.units_for(provider: "workers_ai", model: model, input_tokens: 1_000, output_tokens: 100)
    with = Ai::Budget.units_for(provider: "workers_ai", model: model, input_tokens: 1_000, output_tokens: 100, images: 2)

    assert_equal 60, with - without
  end

  test "an unknown model uses the conservative default rates" do
    known = Ai::Budget.units_for(provider: "workers_ai", model: MODEL, input_tokens: 10_000, output_tokens: 1_000)
    unknown = Ai::Budget.units_for(provider: "workers_ai", model: "@cf/new/model", input_tokens: 10_000, output_tokens: 1_000)

    assert_operator unknown, :>=, known
  end

  test "providers without a daily allocation count plain tokens" do
    assert_equal 2_300, Ai::Budget.units_for(provider: "anthropic", model: "claude-haiku-5-5", input_tokens: 2_000, output_tokens: 300)
    assert_equal 2_300, Ai::Budget.units_for(provider: "ollama", model: "llama3.2", input_tokens: 2_000, output_tokens: 300)
  end

  test "record! adds to the UTC day's row and returns the units" do
    travel_to Time.utc(2026, 11, 4, 1, 30) do # Nov 3 in Denver, Nov 4 in UTC
      units = Ai::Budget.record!(provider: "workers_ai", model: MODEL, input_tokens: 2_000, output_tokens: 300)
      Ai::Budget.record!(provider: "workers_ai", model: MODEL, input_tokens: 2_000, output_tokens: 300)

      assert_equal 115, units
      row = AiUsageDay.find_by!(provider: "workers_ai")
      assert_equal Date.new(2026, 11, 4), row.day
      assert_equal 230, row.units_used
      assert_equal 2, row.requests
      assert_equal 230, Ai::Budget.used_today("workers_ai")
    end
  end

  test "exhausted once today's UTC usage reaches the daily budget" do
    travel_to Time.utc(2026, 11, 3, 12) do
      AiUsageDay.record!(provider: "workers_ai", units: 8_999, day: Date.new(2026, 11, 3))
      assert_not Ai::Budget.exhausted?("workers_ai")
      assert_equal 1, Ai::Budget.remaining("workers_ai")

      AiUsageDay.record!(provider: "workers_ai", units: 1, day: Date.new(2026, 11, 3))
      assert Ai::Budget.exhausted?("workers_ai")
      assert_equal 0, Ai::Budget.remaining("workers_ai")
    end

    travel_to Time.utc(2026, 11, 4, 0, 5) do
      assert_not Ai::Budget.exhausted?("workers_ai"), "a new UTC day starts with a fresh budget"
    end
  end

  test "the budget follows AI_DAILY_NEURON_BUDGET" do
    travel_to Time.utc(2026, 11, 3, 12) do
      AiUsageDay.record!(provider: "workers_ai", units: 500, day: Date.new(2026, 11, 3))

      Ai::Config.with(daily_budget: 500) { assert Ai::Budget.exhausted?("workers_ai") }
      Ai::Config.with(daily_budget: 501) { assert_not Ai::Budget.exhausted?("workers_ai") }
    end
  end

  test "mark_exhausted! uses up the rest of the day so every job waits for the reset" do
    travel_to Time.utc(2026, 11, 3, 12) do
      AiUsageDay.record!(provider: "workers_ai", units: 1_200, day: Date.new(2026, 11, 3))

      assert_equal 7_800, Ai::Budget.mark_exhausted!("workers_ai")
      assert Ai::Budget.exhausted?("workers_ai")
      assert_equal 1, AiUsageDay.find_by!(provider: "workers_ai").requests, "marking is not a request"
      assert_equal 0, Ai::Budget.mark_exhausted!("workers_ai"), "a second mark adds nothing"
    end
  end

  test "a refusal between 00:00 and 00:05 UTC fills the day before, so the 00:05 retry goes ahead" do
    travel_to Time.utc(2026, 11, 4, 0, 2) do
      AiUsageDay.record!(provider: "workers_ai", units: 8_000, day: Date.new(2026, 11, 3))

      assert_equal 1_000, Ai::Budget.mark_exhausted!("workers_ai")
      assert_equal 9_000, AiUsageDay.used_on(Date.new(2026, 11, 3), "workers_ai")
      assert_equal 0, Ai::Budget.used_today("workers_ai")
      assert_equal Time.utc(2026, 11, 4, 0, 5), Ai::Budget.next_reset_at
    end

    travel_to Time.utc(2026, 11, 4, 0, 5) do
      assert_not Ai::Budget.exhausted?("workers_ai")
      assert_equal 9_000, Ai::Budget.mark_exhausted!("workers_ai"), "from 00:05 a refusal fills the new day"
      assert Ai::Budget.exhausted?("workers_ai")
    end
  end

  test "a provider with neither an allocation nor a ceiling is never exhausted" do
    travel_to Time.utc(2026, 11, 3, 12) do
      AiUsageDay.record!(provider: "ollama", units: 9_000_000, day: Date.new(2026, 11, 3))

      assert_not Ai::Budget.limited?("ollama")
      assert_not Ai::Budget.exhausted?("ollama")
      assert_equal 0, Ai::Budget.mark_exhausted!("ollama")
    end
  end

  test "Anthropic has a ceiling on paid tokens per UTC day, and the next day starts fresh" do
    travel_to Time.utc(2026, 11, 3, 12) do
      assert Ai::Budget.limited?("anthropic")
      assert_equal Ai::Config::DEFAULT_DAILY_TOKEN_BUDGET, Ai::Config.daily_budget("anthropic")

      AiUsageDay.record!(provider: "anthropic", units: 1_999_999, day: Date.new(2026, 11, 3))
      assert_not Ai::Budget.exhausted?("anthropic")
      AiUsageDay.record!(provider: "anthropic", units: 1, day: Date.new(2026, 11, 3))
      assert Ai::Budget.exhausted?("anthropic")
    end
    travel_to(Time.utc(2026, 11, 4, 0, 10)) { assert_not Ai::Budget.exhausted?("anthropic") }
  end

  test "Anthropic's rate limit doesn't end its day, and its usage stays in tokens" do
    travel_to Time.utc(2026, 11, 3, 12) do
      assert_equal 0, Ai::Budget.mark_exhausted!("anthropic")
      assert_not Ai::Budget.exhausted?("anthropic")
      assert_equal 2_300, Ai::Budget.units_for(provider: "anthropic", model: "claude-opus-5-5", input_tokens: 2_000, output_tokens: 300)
    end
  end

  test "AI_DAILY_TOKEN_BUDGET is the Anthropic ceiling, not the neuron budget" do
    Ai::Config.with(daily_budget: 500) { assert_equal 500, Ai::Config.daily_budget("anthropic") }
    assert_equal Ai::Config::DEFAULT_DAILY_BUDGET, Ai::Config.daily_budget("workers_ai")
  end

  test "the fake provider is budgeted like Workers AI so tests exercise the guard" do
    assert Ai::Budget.limited?
    travel_to Time.utc(2026, 11, 3, 12) do
      Ai::Budget.mark_exhausted!

      assert Ai::Budget.exhausted?
      assert Ai::Budget.exhausted?("fake")
      assert_not Ai::Budget.exhausted?("workers_ai")
    end
  end
end
