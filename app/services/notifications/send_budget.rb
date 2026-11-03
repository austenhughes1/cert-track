module Notifications
  # The 90/day email guard under Resend's free 100/day cap (the 10 left over cover password
  # resets and other mail sent outside the scan). Days are Denver days (Date.current). Resend
  # doesn't publish a reset time, so the headroom also absorbs any day-boundary mismatch.
  # Backed by EmailSendDay, so counts survive restarts and are shared by concurrent jobs.
  module SendBudget
    DAILY_LIMIT = 90

    module_function

    def sent_today
      EmailSendDay.sent_on(Date.current)
    end

    def remaining_today
      [ DAILY_LIMIT - sent_today, 0 ].max
    end

    # Claims one of today's sends. Returns true when the email may go out, false past the
    # cap: the caller must then hold the email back and call mark_deferred!.
    def reserve!
      EmailSendDay.reserve!(day: Date.current, limit: DAILY_LIMIT)
    end

    # Hands back a reservation that wasn't used (nothing was sent).
    def release!(count = 1)
      EmailSendDay.release!(day: Date.current, by: count)
    end

    # Counts count emails sent without a reservation (e.g. "send test digest"). Never blocks.
    def record!(count = 1)
      EmailSendDay.record_sent!(day: Date.current, by: count)
    end

    # Notes count emails held back by the cap today; the dashboard banner reads this.
    def mark_deferred!(count = 1)
      EmailSendDay.record_deferred!(day: Date.current, by: count)
    end

    def deferred_on?(date)
      EmailSendDay.deferred_on(date).positive?
    end

    # The most recent of today's and yesterday's EmailSendDay rows that deferred mail, or nil.
    def recent_deferral(today: Date.current)
      EmailSendDay.with_deferrals.where(day: (today - 1)..today).order(day: :desc).first
    end
  end
end
