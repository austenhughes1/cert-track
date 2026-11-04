module Imports
  # Deletes import attachments (ImportBatch#uploads, ImportItem#file) and the stored file of
  # each one that nothing else holds any more.
  #
  #   Imports::FileCleanup.delete(batch.uploads_attachments) # => 2 (attachments deleted)
  #
  # A blob still attached elsewhere stays: a single-file upload's blob is also its item's
  # file, and a photo holding several certificates is shared by its items and the
  # certificates made from them. The attachment rows are deleted without callbacks, so the
  # items and batches aren't touched (the 30-day retention counts from updated_at). Each
  # freed blob is purged by a background job, and Active Storage won't purge a blob that was
  # attached again in the meantime.
  module FileCleanup
    def self.delete(attachments)
      attachments = attachments.to_a
      return 0 if attachments.empty?

      deleted = ActiveStorage::Attachment.where(id: attachments.map(&:id)).delete_all
      blob_ids = attachments.map(&:blob_id).uniq
      held = ActiveStorage::Attachment.where(blob_id: blob_ids).distinct.pluck(:blob_id)
      ActiveStorage::Blob.where(id: blob_ids - held).find_each(&:purge_later)
      deleted
    end
  end
end
