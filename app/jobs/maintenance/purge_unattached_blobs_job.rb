module Maintenance
  # Nightly (config/recurring.yml): deletes blobs nothing ever attached, such as direct
  # uploads from a certificate form that was never submitted. They can hold personal data.
  # Packets, HEIC conversions, variants and previews attach their blobs at once, so the
  # grace period only has to outlast an open form.
  class PurgeUnattachedBlobsJob < ApplicationJob
    GRACE_PERIOD = 2.days

    queue_as :default

    # Returns the number of blobs queued for purging.
    def perform
      count = 0
      ActiveStorage::Blob.unattached.where(created_at: ...GRACE_PERIOD.ago).find_each do |blob|
        blob.purge_later
        count += 1
      end
      count
    end
  end
end
