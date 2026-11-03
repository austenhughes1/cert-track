module Certificates
  # Replaces a certificate's HEIC/HEIF phone photos with JPEGs ("IMG_0042.heic" becomes
  # "IMG_0042.jpg") so every browser can show them. Enqueued by Certificate after commit.
  # Safe to run twice: each original is swapped under a row lock, and a copy that lost
  # the race is purged.
  class ConvertHeicJob < ApplicationJob
    queue_as :default

    JPEG_QUALITY = 85

    # The upload may still be finishing when an attach-and-enqueue happens in one request.
    retry_on ActiveStorage::FileNotFoundError, wait: 10.seconds, attempts: 3

    def perform(certificate)
      certificate.files_attachments.includes(:blob).each do |attachment|
        convert(certificate, attachment) if Certificate::HEIC_CONTENT_TYPES.include?(attachment.blob.content_type)
      end
    end

    private
      def convert(certificate, attachment)
        original = attachment.blob
        jpeg_blob = original.open { |file| upload_jpeg(file, "#{original.filename.base}.jpg") }

        swapped = ActiveStorage::Attachment.transaction do
          next false unless ActiveStorage::Attachment.lock.exists?(attachment.id)

          ActiveStorage::Attachment.create!(record: certificate, name: "files", blob: jpeg_blob)
          attachment.delete
          true
        end

        swapped ? original.purge : jpeg_blob.purge
      end

      # autorot applies any EXIF orientation; strip drops metadata such as GPS location.
      def upload_jpeg(file, filename)
        jpeg = ImageProcessing::Vips.source(file).autorot.convert("jpg").saver(quality: JPEG_QUALITY, strip: true).call
        ActiveStorage::Blob.create_and_upload!(io: jpeg, filename: filename, content_type: "image/jpeg")
      ensure
        jpeg&.close!
      end
  end
end
