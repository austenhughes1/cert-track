module Imports
  # Pipeline step 3: reads an import item's file locally (Imports::TextExtractor, no data
  # leaves the machine), stores the text in extracted_text with "=== page N ===" markers,
  # then hands the item to step 4, Imports::AiExtractJob.
  #
  # A file that can't be read (corrupt, password-protected, unsupported, too big, a tool
  # missing or failing) marks the item failed with the reason in error_message, and the
  # batch checks whether it is finished. A tool timeout (a busy machine) or a blob not yet
  # in storage is retried first. Any other error also fails the item, so a batch never
  # waits forever, and is re-raised so it shows in the jobs dashboard.
  #
  # Items that are no longer pending or extracting (rejected, already done) are left
  # alone, and a deleted item discards the job.
  class ExtractTextJob < ApplicationJob
    queue_as :default

    ERROR_MESSAGE_LIMIT = 1_000

    # Seconds each tool call (pdftotext, pdftoppm, tesseract) may take before it is killed.
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
      result = item.file.open do |file|
        TextExtractor.new(file.path, content_type: item.file.content_type, timeout: tool_timeout).call
      end
      item.update!(extracted_text: result.text, error_message: nil)

      Imports::AiExtractJob.perform_later(item)
    end

    private
      def fail_item(error, message: error.message)
        item = arguments.first
        item = ImportItem.find_by(id: item.id) if item.is_a?(ImportItem)
        return unless item && (item.pending? || item.extracting?)

        item.update!(status: :failed, error_message: message.to_s.truncate(ERROR_MESSAGE_LIMIT))
        item.import_batch.check_completion!
      end
  end
end
