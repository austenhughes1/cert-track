module Verification
  # Checks an import item's or a certificate's authenticity in the background (Verification::Run),
  # asking the issuer's site when VERIFICATION_AUTO_CHECKS is on. "Check again" enqueues it with
  # force: true and requested_at (when the page it was pressed on was shown, at the latest when it
  # was pressed: AuthenticityChecksController.recheck_requested_at), which replaces the person's
  # result shown then; a person's result recorded after that, or without force, stays.
  #
  #   Verification::CheckJob.perform_later(certificate)
  #   Verification::CheckJob.perform_later(item, force: true, requested_at: Time.current)
  #
  # An import item that was accepted also has its certificate checked again (right after the
  # item, so a network check of the certificate usually waits its turn: see below), an item
  # accepted while its own check ran included (Imports::Accept copied the check that was still
  # waiting for the issuer's answer), never with
  # force: "Check again" on an item needs it to be waiting for review, so its certificate didn't
  # exist yet, and the person's result Imports::Accept copied onto it is newer than the click.
  # A certificate's QR codes are read from its files (Certificates::QrReader, locally) for the
  # suspicious-link and QR details rules.
  #
  # When the issuer's site was asked moments ago, Run schedules this job again (attempt: 1, 2, ...,
  # up to BUSY_ATTEMPTS) after busy_wait, without force, so a result a person records meanwhile stays.
  # A deleted record discards the job. An unexpected error records nothing and is re-raised, so it
  # shows in the jobs dashboard.
  class CheckJob < ApplicationJob
    # Reading a certificate's QR codes is CPU work like OCR, so it runs on the import worker
    # (config/queue.yml), not the one that sends mail and runs backups. At the default priority it
    # goes ahead of the OCR backlog (Imports::ExtractTextJob's priority 10).
    queue_as :imports

    BUSY_ATTEMPTS = 8

    discard_on ActiveJob::DeserializationError, ActiveRecord::RecordNotFound
    retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3 # with the same arguments, force and requested_at too

    # Seconds before retry number attempt + 1: past HttpClient's interval, spread out so that many
    # certificates waiting for one site take turns.
    def self.busy_wait(attempt)
      interval = Config.min_request_interval
      (interval + 1 + rand(interval * (2**attempt))).seconds
    end

    def perform(record, force: false, requested_at: nil, attempt: 0)
      result = Run.new(record, force: force, requested_at: requested_at, attempt: attempt, **barcodes_for(record)).call
      return unless record.is_a?(ImportItem)
      return if result&.unavailable? && result.details["unavailable"] == "busy" # its retry checks the certificate too

      # Looked up again: a reviewer may have accepted the item while its site was asked, copying the
      # check that was still waiting for the answer onto the new certificate.
      certificate = Certificate.find_by(id: ImportItem.where(id: record.id).pick(:certificate_id))
      Run.new(certificate, attempt: attempt, **barcodes_for(certificate)).call if certificate
    end

    private
      # A certificate's QR codes, read from its files; an import item's are stored on it.
      def barcodes_for(record)
        return {} unless record.is_a?(Certificate)

        barcodes = record.files.flat_map do |file|
          file.open { |tempfile| Certificates::QrReader.new(tempfile.path, content_type: file.content_type).call }
        rescue ActiveStorage::FileNotFoundError
          []
        end
        { barcodes: barcodes }
      end
  end
end
