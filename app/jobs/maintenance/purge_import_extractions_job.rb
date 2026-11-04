module Maintenance
  # Nightly (config/recurring.yml), as the privacy rules require, ImportItem::PURGE_AFTER (30
  # days) after the fact:
  # - deletes the files of failed import items (ImportItem.purge_stale_files!); rejected items
  #   keep theirs, as the original a later upload of the file duplicates;
  # - deletes any raw uploads a batch still holds (ImportBatch.purge_stale_uploads!: only kept
  #   when unpacking stopped part way);
  # - clears extracted_text and extraction from items that finished (accepted, rejected,
  #   duplicate or failed).
  # The items and the resulting certificates are kept; items still waiting for review are
  # left alone.
  class PurgeImportExtractionsJob < ApplicationJob
    queue_as :default

    # Returns { files:, uploads:, extractions: }, the number of each deleted or cleared.
    def perform
      now = Time.current
      # Files first: clearing the text counts as a change, which restarts the item's 30 days.
      counts = { files: ImportItem.purge_stale_files!(now:), uploads: ImportBatch.purge_stale_uploads!(now:),
                 extractions: ImportItem.purge_stale_extractions!(now:) }
      Rails.logger.info("[imports] purged #{counts[:files]} failed items' files, #{counts[:uploads]} old uploads " \
                        "and #{counts[:extractions]} items' extracted text")
      counts
    end
  end
end
