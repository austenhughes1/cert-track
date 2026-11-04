module Maintenance
  # Nightly (config/recurring.yml): clears extracted_text and extraction from import items
  # that finished (accepted, rejected, duplicate or failed) more than ImportItem::PURGE_AFTER
  # (30 days) ago, as the privacy rules require. The item, its file and the resulting
  # certificate are kept; items still waiting for review are left alone.
  class PurgeImportExtractionsJob < ApplicationJob
    queue_as :default

    # Returns the number of items cleared.
    def perform
      ImportItem.purge_stale_extractions!
    end
  end
end
