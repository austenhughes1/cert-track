module Ai
  # The daily free-allocation guard. Workers AI gives 10,000 neurons a day, reset at 00:00 UTC;
  # the app allows itself Ai::Config.daily_budget (9,000) of them and records what each call
  # costs in ai_usage_days, keyed by the UTC day. A quota error from the provider marks the day
  # as used up, so every waiting job sleeps until just after the reset.
  #
  #   Ai::Budget.exhausted?                  # => true once today's (UTC) usage reaches the budget
  #   Ai::Budget.record!(provider: "workers_ai", model: "@cf/...", input_tokens: 1800, output_tokens: 240)
  #   Ai::Budget.next_reset_at               # => the next 00:05 UTC
  #
  # Only providers with a daily allocation (workers_ai, and fake so tests exercise this) are
  # limited. Anthropic and Ollama usage is recorded as plain tokens and never blocks.
  module Budget
    RESET_OFFSET = 5.minutes # wait a little past 00:00 UTC so the allocation has really reset

    class << self
      def limited?(provider = Ai::Config.provider)
        Ai::Config.daily_allocation?(provider)
      end

      def exhausted?(provider = Ai::Config.provider, now: Time.current)
        limited?(provider) && used_today(provider, now: now) >= Ai::Config.daily_budget
      end

      # Units recorded today (UTC) for provider: neurons for Workers AI, tokens otherwise.
      def used_today(provider = Ai::Config.provider, now: Time.current)
        AiUsageDay.used_on(utc_day(now), provider)
      end

      def remaining(provider = Ai::Config.provider, now: Time.current)
        [ Ai::Config.daily_budget - used_today(provider, now: now), 0 ].max
      end

      # Records one call and returns the units it cost (Integer).
      def record!(provider:, model:, input_tokens:, output_tokens:, images: 0, now: Time.current)
        units = units_for(provider: provider, model: model, input_tokens: input_tokens,
          output_tokens: output_tokens, images: images)
        AiUsageDay.record!(provider: provider, units: units, day: utc_day(now))
        units
      end

      # Neurons (rounded up) from config/ai_models.yml rates for daily-allocation providers;
      # input + output tokens for the others.
      def units_for(provider:, model:, input_tokens:, output_tokens:, images: 0)
        input = input_tokens.to_i
        output = output_tokens.to_i
        return input + output unless limited?(provider)

        rates = Ai::Config.model_settings(model)
        neurons = (input * rates[:input_per_million].to_f + output * rates[:output_per_million].to_f) / 1_000_000 +
          images.to_i * rates[:per_image].to_f
        neurons.ceil
      end

      # The provider said no for quota reasons: count today as fully used so every other job
      # waits for the reset instead of hitting the API again. Returns the units added.
      def mark_exhausted!(provider = Ai::Config.provider, now: Time.current)
        return 0 unless limited?(provider)

        shortfall = remaining(provider, now: now)
        AiUsageDay.record!(provider: provider, units: shortfall, day: utc_day(now), requests: 0)
        shortfall
      end

      # The next 00:05 UTC strictly after now.
      def next_reset_at(now = Time.current)
        utc = now.utc
        reset = utc.beginning_of_day + RESET_OFFSET
        reset <= utc ? reset + 1.day : reset
      end

      private
        def utc_day(now)
          now.utc.to_date
        end
    end
  end
end
