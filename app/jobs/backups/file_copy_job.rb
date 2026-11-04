module Backups
  # Nightly at 04:15 Denver (config/recurring.yml): copies new certificate files from R2 to the
  # VM's own disk (Backups::FileCopy). Does nothing, and logs it, while FILE_COPY_DIR is unset
  # (development and test). A missing or read-only folder raises so Solid Queue records it;
  # low disk space and files that failed to copy are reported and shown on the admin dashboard.
  class FileCopyJob < ApplicationJob
    queue_as :default

    # Returns the Backups::FileCopy::Result, or nil when copies are off.
    def perform
      store = FileCopyStore.configured
      if store.nil?
        Rails.logger.info("[Backups] FILE_COPY_DIR is not set; skipping the nightly file copy")
        return
      end

      FileCopy.new(store:).call
    end
  end
end
