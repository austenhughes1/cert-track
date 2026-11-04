module Imports
  # Pipeline step 4: sends an item's OCR text (and, for unreadable pages, page images) to the
  # configured AI model with Imports::Extractor, stores the normalized JSON in item.extraction,
  # then hands the item to steps 5 to 9, Imports::ProcessExtractionJob.
  #
  # Staying inside Workers AI's free allocation:
  #   - when today's (UTC) usage has reached AI_DAILY_NEURON_BUDGET, the item is parked:
  #     next_attempt_at is set and the job re-enqueues itself for the next 00:05 UTC,
  #     just after the allocation resets (Ai::Budget.next_reset_at). Ai::Client checks this
  #     before every call too, so a file needing several calls stops when the budget runs out;
  #   - an HTTP 429 or quota error (Ai::QuotaExceeded) marks the day as used up and parks the
  #     item the same way (a provider without a daily allocation waits RETRY_WITHOUT_DAILY_RESET);
  #   - each finished call is saved in item.extraction (Imports::Extractor.partial_extraction)
  #     as soon as it returns, so a parked or retried file resumes where it stopped instead of
  #     paying for those calls again;
  #   - a file estimated to need more than a whole day's budget fails at once with a message
  #     saying to split it (Imports::Extractor::OverBudget), before any call.
  # Usage is recorded per call by Ai::Client, so retries and unparseable replies count too.
  # item.ai_units_used adds each finished read to the ones before (Imports::Reread keeps it).
  #
  # Settings problems (no EXTRACTION_MODEL, no API token, unreadable pages and nothing else
  # readable without a vision model) fail the item at once with a message saying what to set,
  # as does a page image that can't be rendered for the vision model.
  # Provider and reply errors are retried, then fail the item. Any other error fails the item
  # too, so a batch never waits forever, and is re-raised for the jobs dashboard. After a
  # failure the batch checks whether it is finished.
  #
  # Only items still extracting are touched; a deleted item discards the job.
  class AiExtractJob < ApplicationJob
    queue_as :imports # the import worker (config/queue.yml); see Imports::ExpandJob

    ATTEMPTS = 3
    ERROR_MESSAGE_LIMIT = 1_000

    # Handlers declared later win: the catch-all comes first.
    rescue_from(StandardError) do |error|
      fail_item("AI extraction failed unexpectedly (#{error.class.name}): #{error.message}")
      raise error
    end
    rescue_from(Ai::ConfigurationError, Imports::Extractor::OverBudget) { |error| fail_item(error.message) }
    # Rendering a page image for the vision model failed (corrupt page, tool failure).
    rescue_from(Imports::TextExtractor::Error, Imports::Shell::Error) do |error|
      fail_item("The page image for the vision model could not be made: #{error.message}")
    end
    discard_on ActiveJob::DeserializationError
    retry_on Ai::ProviderError, Ai::ResponseError, wait: :polynomially_longer, attempts: ATTEMPTS do |job, error|
      job.send(:fail_item, "AI extraction failed after #{ATTEMPTS} attempts: #{error.message}")
    end

    def perform(item)
      return unless item.extracting?
      return Imports::ProcessExtractionJob.perform_later(item) if Imports::Extractor.finished?(item.extraction) # a repeat run

      provider = Ai::Config.provider
      Ai::Config.ensure_ready!(provider)
      return park(item) if Ai::Budget.exhausted?(provider)

      result = extract(item, provider)
      return unless result

      item.update!(extraction: result.data, provider: result.provider, ai_units_used: item.ai_units_used.to_i + result.units,
        attempts: item.attempts + 1, next_attempt_at: nil, error_message: nil)
      Rails.logger.info("[ai] import item #{item.id}: #{result.requests} call(s) to #{result.model}, " \
        "#{result.units} #{Ai::Budget.limited?(provider) ? "neurons" : "tokens"}")
      Imports::ProcessExtractionJob.perform_later(item)
    end

    private
      # The Extractor result, or nil when the item was parked for quota. Every finished call is
      # saved on the item as it comes back, for a resumed run to reuse.
      def extract(item, provider)
        Imports::Extractor.new(item, done: Imports::Extractor.saved_calls(item.extraction)).call do |calls|
          item.update!(extraction: Imports::Extractor.partial_extraction(calls))
        end
      rescue Ai::QuotaExceeded => error
        Ai::Budget.mark_exhausted!(provider)
        park(item, retry_at: error.retry_at)
        nil
      rescue Ai::ProviderError, Ai::ResponseError
        item.update!(attempts: item.attempts + 1)
        raise
      end

      # Waits for the daily reset (or retry_at) and tries again then.
      def park(item, retry_at: nil)
        at = retry_at || Ai::Budget.next_reset_at
        item.update!(next_attempt_at: at)
        self.class.set(wait_until: at).perform_later(item)
        Rails.logger.info("[ai] import item #{item.id} waits for the AI allocation until #{at.utc.iso8601}")
      end

      def fail_item(message)
        item = arguments.first
        item = ImportItem.find_by(id: item.id) if item.is_a?(ImportItem)
        return unless item&.extracting?

        item.update!(status: :failed, error_message: message.to_s.truncate(ERROR_MESSAGE_LIMIT), next_attempt_at: nil)
        item.import_batch.check_completion!
      end
  end
end
