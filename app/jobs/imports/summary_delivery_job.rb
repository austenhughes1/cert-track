module Imports
  # ImportMailer's delivery job (ImportMailer.delivery_job), so the import summary that
  # ImportBatch#check_completion! sends once per batch counts against the 90/day email cap
  # like every other email (Notifications::SendBudget, docs/PLAN.md "Delivery").
  #
  # Each send first reserves one of today's (Denver) sends. Past the cap the email is held
  # back, counted as deferred (the dashboard banner) and retried the next morning at
  # RETRY_AT_HOUR, after the 6:00 expiry scan and the 6:30 digest retries have had first
  # claim on the day's sends. It is never dropped, and the batch never gets a second one. A
  # failed delivery hands its reservation back and raises (it shows in the jobs dashboard),
  # so a retry from there reserves again.
  #
  # Runs on the mailer's queue (default), not imports: mail never waits behind an import backlog.
  class SummaryDeliveryJob < ActionMailer::MailDeliveryJob
    RETRY_AT_HOUR = 7 # a.m. Denver, the day after the cap held the email back

    discard_on ActiveJob::DeserializationError # the batch was deleted before its summary went out

    def perform(...)
      unless Notifications::SendBudget.reserve!
        Notifications::SendBudget.mark_deferred!
        retry_job(wait_until: Date.tomorrow.in_time_zone.change(hour: RETRY_AT_HOUR))
        return
      end

      begin
        super
      rescue StandardError
        Notifications::SendBudget.release!
        raise
      end
    end
  end
end
