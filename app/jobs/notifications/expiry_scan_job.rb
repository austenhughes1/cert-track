module Notifications
  # Daily at 6:00 a.m. Denver (config/recurring.yml): expiry digests to managers and
  # opt-in crew notices. See Notifications::ExpiryScan for the rules.
  class ExpiryScanJob < ApplicationJob
    class DeliveryFailed < StandardError; end

    queue_as :default

    # Raises after the run when any email failed, so Solid Queue records the failure. Each
    # failed email's log rows were dropped, so the next run (or a manual retry) resends only those.
    def perform
      result = Notifications::ExpiryScan.call
      return result if result.failures.empty?

      raise DeliveryFailed, "#{result.failures.size} expiry email(s) failed (first: " \
        "#{result.failures.first.class}: #{result.failures.first.message}); they will be retried on the next run"
    end
  end
end
