module Notifications
  # The daily expiry email run (Notifications::ExpiryScanJob, 6:00 a.m. Denver).
  #
  # Each certificate's most urgent crossed threshold goes once to every digest recipient,
  # bundled into one daily_digest per recipient, and, at d30 and d7 only, to its crew member
  # when they opted in and have an email. A threshold is skipped for a recipient who already
  # got it or a more urgent one, so a missed week sends only the most urgent, never a burst.
  #
  # Per email: reserve a send under the daily email cap (past it, defer: no log rows, so the next
  # run picks the items up), claim the send-log rows with INSERT ... ON CONFLICT DO NOTHING,
  # send only what this run claimed, then stamp sent_at. Concurrent or repeated runs can't
  # double-send. A failed delivery drops its claims and its reservation, so the next run retries it.
  class ExpiryScan
    Result = Data.define(:digests_sent, :crew_notices_sent, :items_sent, :deferred, :failures)

    def self.call(today: Date.current)
      new(today: today).call
    end

    def initialize(today: Date.current)
      @today = today
      @counts = Hash.new(0)
      @failures = []
    end

    def call
      items = DigestBuilder.daily_items(today: @today)

      if items.any?
        log = sent_log(items)
        send_digests(items, log)
        send_crew_notices(items, log)
      end

      Result.new(digests_sent: @counts[:digests], crew_notices_sent: @counts[:crew_notices],
        items_sent: @counts[:items], deferred: @counts[:deferred], failures: @failures)
    end

    private
      # Manager digests go first so they win when the cap bites.
      def send_digests(items, log)
        User.digest_recipients.order(:id).each do |user|
          email = user.email_address.downcase
          fresh = items.reject { |item| Threshold.covered?(item.threshold, log[[ item.certificate.id, email ]]) }
          next if fresh.empty?

          deliver(fresh, email, :digests) do |claimed|
            ExpiryMailer.with(user: user, items: claimed).daily_digest.deliver_now
          end
        end
      end

      def send_crew_notices(items, log)
        items.each do |item|
          crew_member = item.crew_member
          next unless crew_member.expiry_emails_opt_in? && crew_member.email.present? && Threshold.crew?(item.threshold)

          email = crew_member.email.downcase
          next if Threshold.covered?(item.threshold, log[[ item.certificate.id, email ]])

          deliver([ item ], email, :crew_notices) do |_claimed|
            ExpiryMailer.with(crew_member: crew_member, certificate: item.certificate, threshold: item.threshold)
              .crew_notice.deliver_now
          end
        end
      end

      def deliver(items, email, kind)
        unless SendBudget.reserve!
          SendBudget.mark_deferred!
          @counts[:deferred] += 1
          return
        end

        claims = claim(items, email)
        if claims.empty? # a concurrent run claimed these first
          SendBudget.release!
          return
        end

        claimed = items.select { |item| claims.key?(item.certificate.id) }
        begin
          yield claimed
        rescue StandardError => error
          ExpiryNotification.where(id: claims.values).delete_all
          SendBudget.release!
          @failures << error
          Rails.logger.error("[ExpiryScan] delivery to #{email} failed: #{error.class}: #{error.message}")
          Rails.error.report(error, handled: true, context: { recipient_email: email, certificate_ids: claims.keys })
          return
        end

        now = Time.current
        ExpiryNotification.where(id: claims.values).update_all(sent_at: now, updated_at: now)
        @counts[kind] += 1
        @counts[:items] += claimed.size
      end

      # Inserts send-log rows (sent_at nil until delivered) and returns
      # {certificate_id => notification_id} for the rows this call actually inserted.
      def claim(items, email)
        now = Time.current
        rows = items.map do |item|
          { certificate_id: item.certificate.id, threshold: item.threshold, recipient_email: email,
            created_at: now, updated_at: now }
        end

        ExpiryNotification.insert_all(rows, unique_by: :index_expiry_notifications_uniqueness,
          returning: %w[id certificate_id]).rows.to_h { |id, certificate_id| [ certificate_id, id ] }
      end

      # {[certificate_id, recipient_email] => most urgent threshold logged}. Rows still unsent
      # (a crashed run) count as logged: at most once beats a duplicate.
      def sent_log(items)
        ExpiryNotification.where(certificate_id: items.map { |item| item.certificate.id })
          .pluck(:certificate_id, :recipient_email, :threshold)
          .group_by { |certificate_id, email, _| [ certificate_id, email.downcase ] }
          .transform_values { |rows| Threshold.most_urgent(rows.map(&:last)) }
      end
  end
end
