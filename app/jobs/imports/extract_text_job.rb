module Imports
  # Pipeline step 3: reads an import item's file locally (Imports::TextExtractor, no data
  # leaves the machine), stores the text in extracted_text with "=== page N ===" markers,
  # then the QR codes in barcodes (Certificates::QrReader, Phase 3b; page numbers of this
  # file), then hands the item to step 4, Imports::AiExtractJob. QR codes are a bonus: a file
  # whose codes can't be read (or a machine without zbarimg) just stores none.
  #
  # A file that can't be read (corrupt, password-protected, unsupported, too big, a tool
  # missing or failing) marks the item failed with the reason in error_message, and the
  # batch checks whether it is finished. A tool timeout (a busy machine) or a blob not yet
  # in storage is retried first. Any other error also fails the item, so a batch never
  # waits forever, and is re-raised so it shows in the jobs dashboard.
  #
  # Text already stored is used as it is, without running the tools again: an item sent back
  # through the pipeline (Imports::Reread, which clears a PDF item's text first: it may hold
  # only the item's pages), or a run that died after saving it. Stored QR codes are kept the
  # same way; an item with none is read for them again. Pages with a QR code that couldn't be
  # decoded go in unread_qr_pages, for the image quality flag (Imports::ImageQuality).
  #
  # Before anything else, a file whose content is the same as an earlier upload's (a re-saved copy,
  # Imports::ContentDigest) becomes a duplicate of it, so it costs no OCR and no AI call. Read again
  # keeps the digest and doesn't stop here: it is someone asking for a new read.
  #
  # Items that are no longer pending or extracting (rejected, already done) are left
  # alone, and a deleted item discards the job.
  class ExtractTextJob < ApplicationJob
    queue_as :imports # the import worker (config/queue.yml); see Imports::ExpandJob
    # OCR is the slow step, so it goes behind the quick pipeline jobs (Solid Queue runs lower
    # numbers first; the rest have 0): a new batch unpacks, and files already read move on to
    # the AI, while a big batch's OCR backlog drains.
    queue_with_priority 10

    ERROR_MESSAGE_LIMIT = 1_000

    # Seconds each tool call (pdftotext, pdftoppm, tesseract, zbarimg) may take before it is killed.
    class_attribute :tool_timeout, instance_writer: false, default: Shell::DEFAULT_TIMEOUT

    # Handlers declared later win: the catch-all comes first.
    rescue_from(StandardError) do |error|
      fail_item(error, message: "Text extraction failed unexpectedly (#{error.class.name}): #{error.message}")
      raise error
    end
    rescue_from(TextExtractor::Error, Shell::Error) { |error| fail_item(error) }
    discard_on ActiveJob::DeserializationError
    retry_on Shell::TimedOut, ActiveStorage::FileNotFoundError, wait: 30.seconds, attempts: 3 do |job, error|
      missing = error.is_a?(ActiveStorage::FileNotFoundError)
      job.send(:fail_item, error, message: missing ? "The uploaded file is missing from storage" : error.message)
    end

    def perform(item)
      return unless item.pending? || item.extracting?
      raise TextExtractor::Error, "The import item has no file attached" unless item.file.attached?

      item.extracting!
      return if same_content_as_earlier_upload?(item)

      read_file(item) if item.extracted_text.nil? || item.barcodes.blank?

      Imports::AiExtractJob.perform_later(item)
    end

    private
      # Only on a first read: an item with a digest, stored text or AI usage is a resumed run or Read
      # again. Under an advisory lock on the digest, so of two copies arriving together only one is read.
      def same_content_as_earlier_upload?(item)
        return false if item.content_digest.present? || item.source_item_id.present? || item.extracted_text.present? || item.ai_units_used.to_i.positive?

        digest = item.file.open { |file| ContentDigest.new(file.path, content_type: item.file.content_type, timeout: tool_timeout).call }
        return false if digest.nil?

        original = ImportItem.transaction do
          ImportItem.connection.execute(ImportItem.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "content:#{digest}" ]))
          item.update!(content_digest: digest)
          ImportItem.original_for_content(digest, except: item)
        end
        return false unless original

        item.mark_duplicate_of!(original)
        item.file.purge_later # a duplicate holds no file: the original's is the one kept
        item.import_batch.check_completion!
        true
      rescue ActiveStorage::FileNotFoundError
        false # the text step reports a missing file
      end

      # The text unless it is stored already, then the QR codes unless they are. A file missing
      # from storage only matters for the text: without it, the item goes on with no QR codes.
      def read_file(item)
        item.file.open do |file|
          if item.extracted_text.nil?
            result = TextExtractor.new(file.path, content_type: item.file.content_type, timeout: tool_timeout).call
            item.update!(extracted_text: result.text, ocr_pages: result.pages.select(&:ocr).map(&:number), error_message: nil)
          end
          if item.barcodes.blank?
            reader = Certificates::QrReader.new(file.path, content_type: item.file.content_type, timeout: tool_timeout)
            barcodes = reader.call
            item.update!(barcodes: barcodes, unread_qr_pages: ImageQuality.unread_qr_pages(item.extracted_text,
              undecoded_pages: reader.undecoded_pages, decoded_pages: barcodes.map { |code| code["page"] }))
          end
        end
      rescue ActiveStorage::FileNotFoundError
        raise if item.extracted_text.nil?

        Rails.logger.warn("[Imports::ExtractTextJob] import item #{item.id}: QR codes not read, the file is missing from storage")
      end

      def fail_item(error, message: error.message)
        item = arguments.first
        item = ImportItem.find_by(id: item.id) if item.is_a?(ImportItem)
        return unless item && (item.pending? || item.extracting?)

        item.update!(status: :failed, error_message: message.to_s.truncate(ERROR_MESSAGE_LIMIT))
        item.import_batch.check_completion!
      end
  end
end
