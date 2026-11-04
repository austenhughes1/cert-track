require "vips"

module Certificates
  # Stores a certificate's new photos and scans smaller; the full-size original is not kept
  # (the owner's choice, 2026-11-04). Enqueued by Certificate after a save that attaches files,
  # with the ids of the attachments that save created.
  #
  # - An image (JPEG, PNG, WEBP, HEIC/HEIF) becomes a JPEG of at most 2400 px a side, quality
  #   80, with the same name ("IMG_0042.heic" becomes "IMG_0042.jpg"; Certificates::ImageShrinker).
  # - A scanned PDF keeps its pages and text; only its big page images are re-encoded at
  #   200 ppi (Certificates::PdfShrinker). A PDF made on a computer is left alone.
  #
  # The smaller copy replaces the file only when it is under 80% of its size, with two
  # exceptions that are always replaced: HEIC/HEIF, which browsers can't show, and an image
  # with EXIF, XMP or IPTC metadata (a phone photo's GPS location, time and phone), so no
  # stored photo keeps it. A file that can't be read is kept as it is, metadata included.
  #
  # Safe to run twice: each original is swapped under a row lock, a copy that lost the race is
  # purged, and the copies it makes are marked (blob metadata) so they're never shrunk again.
  class ShrinkFilesJob < ApplicationJob
    # CPU work like OCR, so it runs on the import worker and never delays backups or mail
    # (config/queue.yml). At the default priority it goes ahead of an OCR backlog.
    queue_as :imports

    MAX_SHARE = 0.8 # a smaller copy must be under this share of the original's bytes
    SHRUNK_KEY = "shrunk" # blob metadata set on every copy this job makes
    IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze
    PDF_CONTENT_TYPE = "application/pdf".freeze

    # The upload may still be finishing when an attach-and-enqueue happens in one request.
    retry_on ActiveStorage::FileNotFoundError, wait: 10.seconds, attempts: 3
    discard_on ActiveJob::DeserializationError # the certificate was deleted first

    def perform(certificate, attachment_ids)
      certificate.files_attachments.where(id: attachment_ids).includes(:blob).order(:id).each do |attachment|
        shrink(certificate, attachment)
      end
    end

    private
      def shrink(certificate, attachment)
        original = attachment.blob
        heic = Certificate::HEIC_CONTENT_TYPES.include?(original.content_type)
        return if original.metadata[SHRUNK_KEY] && !heic

        Dir.mktmpdir("certtrack-shrink-") do |dir|
          copy = original.open(tmpdir: dir) { |file| smaller_copy(original, file.path, dir, always: heic) }
          swap(certificate, attachment, upload(copy, original)) if copy
        end
      rescue ImageShrinker::Error, Vips::Error => error
        Rails.logger.warn("[Certificates::ShrinkFilesJob] blob #{original.id} kept as it is: " \
          "#{error.class}: #{error.message.to_s.lines.last.to_s.strip.truncate(200)}")
      end

      # The path of the smaller copy, or nil when the original stays.
      def smaller_copy(original, path, dir, always:)
        under = original.byte_size * MAX_SHARE

        if IMAGE_CONTENT_TYPES.include?(original.content_type)
          jpeg = ImageShrinker.write_jpeg(path, File.join(dir, "shrunk.jpg"))
          jpeg if always || File.size(jpeg) < under || ImageShrinker.metadata?(path)
        elsif original.content_type == PDF_CONTENT_TYPE
          PdfShrinker.new(path, File.join(dir, "shrunk.pdf"), under: under).call
        end
      end

      def upload(path, original)
        image = IMAGE_CONTENT_TYPES.include?(original.content_type)
        File.open(path, "rb") do |io|
          ActiveStorage::Blob.create_and_upload!(io: io,
            filename: image ? "#{original.filename.base}.jpg" : original.filename.to_s,
            content_type: image ? "image/jpeg" : PDF_CONTENT_TYPE, metadata: { SHRUNK_KEY => true })
        end
      end

      # The original goes only if this run wins the swap. purge does nothing while another
      # record (an import item, or a second certificate cut from the same photo) still uses it.
      def swap(certificate, attachment, copy)
        swapped = ActiveStorage::Attachment.transaction do
          next false unless ActiveStorage::Attachment.lock.exists?(attachment.id)

          ActiveStorage::Attachment.create!(record: certificate, name: "files", blob: copy)
          attachment.delete
          true
        end

        swapped ? attachment.blob.purge : copy.purge
      end
  end
end
