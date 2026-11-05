module Certificates
  # Reads the QR codes on files just attached to a certificate (Certificates::QrReader, locally;
  # docs/PLAN.md, Phase 3b), so a certificate entered by hand gets its verification link from its
  # QR code, then has its authenticity checked (Verification::CheckJob, which reads the QR codes of
  # all its files for its own rules). Enqueued by Certificate after a save that attaches files, with
  # the ids of the attachments that save created. A certificate made by an import is not: the
  # pipeline read its QR codes, and Imports::Accept copies the link and the check.
  #
  # Without a verification_url, the certificate takes the first QR link on its issuer's domain,
  # else the first on any active issuer's domain, and that issuer when it has none. A link it
  # already has, typed by a person, is kept, and so is everything on a certificate a person
  # confirmed fake (what they checked).
  #
  # The files are read as uploaded when they can be: Certificates::ShrinkFilesJob, which may
  # replace them with smaller copies, runs on the same worker and is queued just after this job.
  # When it got there first (the given attachments are gone), the certificate's current files
  # are read instead: the smaller copies, which still read in nearly every case.
  class ReadQrCodesJob < ApplicationJob
    # CPU work like the shrink job and OCR, so it runs on the import worker (config/queue.yml).
    queue_as :imports

    # The upload may still be finishing, or the shrink job deleted the original mid-download.
    retry_on ActiveStorage::FileNotFoundError, wait: 10.seconds, attempts: 3
    discard_on ActiveJob::DeserializationError, ActiveRecord::RecordNotFound # the certificate was deleted first
    retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

    def perform(certificate, attachment_ids)
      texts = attachments_to_read(certificate, attachment_ids).flat_map { |attachment| qr_texts(attachment.blob) }
      assign_verification_link(certificate, texts) if texts.any?

      Verification::CheckJob.perform_later(certificate)
    end

    private
      def attachments_to_read(certificate, attachment_ids)
        ids = Array(attachment_ids).uniq
        given = certificate.files_attachments.where(id: ids).includes(:blob).order(:id).to_a
        return given if given.size == ids.size

        certificate.files_attachments.includes(:blob).order(:id).to_a # some were swapped for smaller copies
      end

      def qr_texts(blob)
        blob.open { |file| QrReader.new(file.path, content_type: blob.content_type).call }.map { |code| code["text"] }
      end

      # Under row locks, the crew member's first as Verification::Run and Certificate's saves take
      # them, so a link typed while the files were read is not overwritten. A certificate a person
      # confirmed fake keeps the details they checked: a link filled in here would turn it back into
      # needs a check (Authenticity) though nobody looked at it. Check again reads the QR codes itself.
      def assign_verification_link(certificate, texts)
        links = texts.filter_map { |text| Certificate.normalize_verification_url(text) }.uniq
        return if links.empty?

        Certificate.transaction do
          CrewMember.where(id: certificate.crew_member_id).lock.pluck(:id)
          certificate.lock!
          next if certificate.verification_url.present? || certificate.authenticity_confirmed_fake?

          issuer = certificate.certificate_issuer
          link = (links.find { |url| issuer.owns_url?(url) } if issuer) || links.find { |url| CertificateIssuer.for_url(url) }
          next unless link

          certificate.verification_url = link
          certificate.certificate_issuer ||= CertificateIssuer.for_url(link)
          # Only these two columns change, so a problem elsewhere on an old row must not block them.
          certificate.save!(validate: false)
        end
      end
  end
end
