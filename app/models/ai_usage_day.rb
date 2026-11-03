# Daily AI usage per provider (Workers AI neurons or tokens), for budget checks.
class AiUsageDay < ApplicationRecord
  validates :day, :provider, presence: true
  validates :provider, uniqueness: { scope: :day }
  validates :units_used, :requests, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  class << self
    # Atomically adds units (and one request) to the row for day + provider, creating it if needed.
    # Workers AI's allocation resets at 00:00 UTC, so budget callers pass day: Time.now.utc.to_date.
    def record!(provider:, units:, day: Date.current, requests: 1)
      upsert({ day: day, provider: provider.to_s, units_used: units.to_i, requests: requests },
        unique_by: %i[day provider],
        on_duplicate: Arel.sql(<<~SQL.squish))
          units_used = ai_usage_days.units_used + EXCLUDED.units_used,
          requests = ai_usage_days.requests + EXCLUDED.requests,
          updated_at = EXCLUDED.updated_at
        SQL
    end

    # Units used on day by provider; 0 when nothing was recorded.
    def used_on(day, provider)
      where(day: day, provider: provider.to_s).pick(:units_used) || 0
    end
  end
end
