module Notifications
  # Mondays at 6:00 a.m. Denver (config/recurring.yml): one weekly_digest to every digest
  # recipient, sent even when empty, listing everything expiring within 30 days (expired
  # included) plus missing/expired requirements on active projects.
  #
  # Each email counts against the 90/day cap. Recipients the cap holds back get a retry the
  # next day at 6:30 (after the daily scan), unless that day is Monday and the regular run
  # covers them.
  class WeeklyDigestJob < ApplicationJob
    RETRY_AT_HOUR = 6
    RETRY_AT_MINUTE = 30

    queue_as :default

    # recipient_ids: nil for every digest recipient, or the ids a capped run deferred.
    # Returns the number of digests sent.
    def perform(recipient_ids = nil)
      recipients = User.digest_recipients.order(:id)
      recipients = recipients.where(id: recipient_ids) if recipient_ids
      recipients = recipients.to_a
      return 0 if recipients.empty?

      today = Date.current
      expiring = Notifications::DigestBuilder.weekly_items(today: today)
      gaps = Compliance::Overview.new(Project.active.ordered, today: today).gaps

      sent = 0
      deferred_ids = []
      recipients.each do |user|
        unless Notifications::SendBudget.reserve!
          Notifications::SendBudget.mark_deferred!
          deferred_ids << user.id
          next
        end

        sent += 1 if deliver(user, expiring, gaps)
      end

      retry_tomorrow(deferred_ids, today) if deferred_ids.any?
      sent
    end

    private
      # A failed send is reported and skipped, not raised: a job retry would resend to everyone.
      def deliver(user, expiring, gaps)
        ExpiryMailer.with(user: user, expiring: expiring, gaps: gaps).weekly_digest.deliver_now
        true
      rescue StandardError => error
        Notifications::SendBudget.release!
        Rails.logger.error("[WeeklyDigestJob] delivery to #{user.email_address} failed: #{error.class}: #{error.message}")
        Rails.error.report(error, handled: true, context: { user_id: user.id })
        false
      end

      def retry_tomorrow(recipient_ids, today)
        tomorrow = today + 1
        return if tomorrow.monday?

        self.class.set(wait_until: tomorrow.in_time_zone.change(hour: RETRY_AT_HOUR, min: RETRY_AT_MINUTE))
          .perform_later(recipient_ids)
      end
  end
end
