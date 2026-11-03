# Durable per-day email counter (one row per Denver day). Notifications::SendBudget
# applies the 90/day policy on top of it. Every write is a single atomic upsert, so
# concurrent jobs can't overshoot the cap or lose increments.
class EmailSendDay < ApplicationRecord
  INCREMENT_SQL = {
    sent_count: "sent_count = email_send_days.sent_count + EXCLUDED.sent_count, updated_at = EXCLUDED.updated_at",
    deferred_count: "deferred_count = email_send_days.deferred_count + EXCLUDED.deferred_count, updated_at = EXCLUDED.updated_at"
  }.freeze

  validates :day, presence: true, uniqueness: true
  validates :sent_count, :deferred_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :with_deferrals, -> { where(deferred_count: 1..) }

  class << self
    # Adds one send to day when fewer than limit were sent. Returns true if the send was
    # reserved, false when the day is already at the limit.
    def reserve!(day:, limit:)
      return false unless limit.positive?

      sql = sanitize_sql_array([ <<~SQL.squish, day, Time.current, Time.current, limit ])
        INSERT INTO email_send_days (day, sent_count, deferred_count, created_at, updated_at)
        VALUES (?, 1, 0, ?, ?)
        ON CONFLICT (day) DO UPDATE
          SET sent_count = email_send_days.sent_count + 1, updated_at = EXCLUDED.updated_at
          WHERE email_send_days.sent_count < ?
        RETURNING id
      SQL
      # exec_query, not select_*: the query cache must never replay this write.
      with_connection { |connection| connection.exec_query(sql, "EmailSendDay Reserve").rows.any? }
    end

    # Unconditionally adds by sends to day (mail sent outside a reservation, e.g. a test digest).
    def record_sent!(day:, by: 1)
      increment_column!(:sent_count, day: day, by: by)
    end

    # Gives back by reserved sends that never went out (never below zero).
    def release!(day:, by: 1)
      where(day: day).update_all([ "sent_count = GREATEST(sent_count - ?, 0), updated_at = ?", by, Time.current ])
    end

    # Notes by sends held back by the cap on day.
    def record_deferred!(day:, by: 1)
      increment_column!(:deferred_count, day: day, by: by)
    end

    def sent_on(day)
      where(day: day).pick(:sent_count) || 0
    end

    def deferred_on(day)
      where(day: day).pick(:deferred_count) || 0
    end

    private
      def increment_column!(column, day:, by:)
        upsert({ day: day, column => by }, unique_by: :day, on_duplicate: Arel.sql(INCREMENT_SQL.fetch(column)))
      end
  end
end
