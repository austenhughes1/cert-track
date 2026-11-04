module Backups
  # certtrack:restore_files: puts files back into storage (R2) from the file copies. For every
  # blob in the database that has a copy, live or in the trash (where the copies of deleted
  # files wait, so a database restore can bring them back), checks whether storage still holds
  # its object and, if not, uploads the copy once its MD5 matches the blob's checksum.
  # A dry run unless confirm: true. Blobs without a copy are only counted, so storage is asked
  # about copied blobs alone (one read each).
  #
  # Thumbnails and previews are never copied, so those of a file that was missing are gone from
  # storage too, while their rows would keep pointing at nothing. Once its file is back, they are
  # deleted, and each is made again from the file the next time a page shows it.
  class FileCopyRestore
    ERRORS_KEPT = 10

    # missing: blobs missing from storage that have a good copy (restored, unless a dry run);
    # from_trash: how many of those copies were in the trash.
    # representations: thumbnails and previews of restored files deleted, to be made again.
    Result = Data.define(:confirm, :blobs, :without_copy, :in_storage, :missing, :from_trash, :restored,
      :bad_copies, :representations, :failed, :errors)

    def initialize(store:, confirm: false)
      @store = store
      @confirm = confirm
    end

    def call
      raise FileCopyStore::DirectoryError, "The file copy folder #{@store.root} does not exist" if @store.problem == :missing

      @counts = Hash.new(0)
      @errors = []
      @restored_ids = []
      ActiveStorage::Blob.find_each do |blob|
        @counts[:blobs] += 1
        @counts[restore(blob)] += 1
      rescue StandardError => error
        record_failure(blob, error)
      end
      forget_representations

      Result.new(confirm: @confirm, blobs: @counts[:blobs], without_copy: @counts[:without_copy],
        in_storage: @counts[:in_storage], missing: @counts[:missing] + @counts[:restored],
        from_trash: @counts[:from_trash], restored: @counts[:restored], bad_copies: @counts[:bad_copy],
        representations: @counts[:representations], failed: @counts[:failed], errors: @errors)
    end

    private
      # :without_copy, :in_storage, :bad_copy, :missing (a dry run) or :restored.
      def restore(blob)
        path = @store.copy_path_for(blob)
        return :without_copy unless path
        return :in_storage if blob.service.exist?(blob.key)
        return :bad_copy unless blob.checksum.nil? || OpenSSL::Digest::MD5.file(path).base64digest == blob.checksum

        if @confirm
          File.open(path, "rb") { |file| blob.upload_without_unfurling(file) }
          @restored_ids << blob.id
          Rails.logger.info("[Backups] restored blob #{blob.id} (#{blob.key}) from #{path}")
        end
        @counts[:from_trash] += 1 if path != @store.path_for(blob.key)
        @confirm ? :restored : :missing
      end

      # After the loop, so the blobs deleted here are counted like every other blob.
      def forget_representations
        ActiveStorage::VariantRecord.where(blob_id: @restored_ids).includes(image_attachment: :blob).find_each do |variant|
          forget(variant.image_blob) do
            variant.image.purge
            variant.delete
          end
        end
        ActiveStorage::Attachment.where(record_type: ActiveStorage::Blob.name, record_id: @restored_ids, name: "preview_image")
          .includes(:blob).find_each { |preview| forget(preview.blob) { preview.purge } }
      end

      def forget(blob)
        yield
        @counts[:representations] += 1
      rescue StandardError => error
        record_failure(blob, error)
      end

      def record_failure(blob, error)
        @counts[:failed] += 1
        @errors << "blob #{blob&.id} (#{blob&.key}): #{error.class.name}: #{error.message}".truncate(300) if @errors.size < ERRORS_KEPT
      end
  end
end
