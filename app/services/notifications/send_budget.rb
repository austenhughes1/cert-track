module Notifications
  # The app's own daily email cap. Mail goes out through the office's Google Workspace account,
  # which Gmail allows about 2,000 emails a day, and the owner's own email from that account
  # counts too. So the app takes MAIL_DAILY_LIMIT of them (default 1,000) and leaves the rest
  # for the owner and for invites and password resets, which aren't counted here. Invites are
  # never held back; resets have their own small caps (PasswordsController).
  # Days are Denver days (Date.current). Gmail counts over a rolling 24 hours instead, so two
  # full days back to back can send up to twice MAIL_DAILY_LIMIT within 24 hours. A send Gmail
  # refuses anyway fails like any other delivery error: the caller hands its reservation back.
  # Backed by EmailSendDay, so counts survive restarts and are shared by concurrent jobs.
  module SendBudget
    DEFAULT_DAILY_LIMIT = 1000

    module_function

    # MAIL_DAILY_LIMIT, or DEFAULT_DAILY_LIMIT when it is unset, not a whole number, or not positive.
    def daily_limit
      limit = Integer(ENV["MAIL_DAILY_LIMIT"].to_s, exception: false)
      limit&.positive? ? limit : DEFAULT_DAILY_LIMIT
    end

    def sent_today
      EmailSendDay.sent_on(Date.current)
    end

    def remaining_today
      [ daily_limit - sent_today, 0 ].max
    end

    # Claims one of today's sends. Returns true when the email may go out, false past the
    # cap: the caller must then hold the email back and call mark_deferred!.
    def reserve!
      EmailSendDay.reserve!(day: Date.current, limit: daily_limit)
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
