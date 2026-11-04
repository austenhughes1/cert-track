module Imports
  # Pipeline step 2 (docs/PLAN.md, "Bulk import pipeline"): unpacks a batch's uploads into
  # one ImportItem per file, through Imports::Archive's zip-slip and zip-bomb guards.
  #
  # - a supported file -> a pending item with the file attached, then Imports::ExtractTextJob
  # - the same bytes as an earlier item (this batch or any other) -> a duplicate item
  #   linked to it, with no file and no AI work
  # - anything refused (unsafe path, unsupported type, over a limit, unreadable zip) -> a
  #   rejected item with the reason, so every file is accounted for
  #
  # Text extraction is enqueued only once every item exists, so no item can finish (and
  # trigger check_completion!) while the batch is still being unpacked. A run that died
  # half way (deploy, crash) is redone from scratch when Solid Queue runs the job again.
  #
  # Once every upload is unpacked, the uploads are deleted (ImportBatch#discard_uploads!): a
  # zip, a rejected or duplicate file, and the whole PDF a split single upload leaves behind
  # are no longer stored twice. A single-file upload's blob stays as its item's file. When
  # unpacking stopped on an unexpected error they are kept, and the nightly
  # ImportBatch.purge_stale_uploads! deletes them after 30 days.
  class ExpandJob < ApplicationJob
    # Every pipeline job runs on the imports queue, which has its own worker (config/queue.yml):
    # a big batch's OCR backlog never holds up backups, expiry emails or mail on default.
    queue_as :imports

    LOCK_NAMESPACE = 0x1e2a # pg advisory lock key space for import batches

    def perform(batch)
      with_batch_lock(batch) do
        next unless claim(batch)

        batch.discard_uploads! if expand(batch)
      end
    end

    private
      # Moves a receiving batch to processing. A processing batch whose unpacking never
      # finished (files_count still 0, nothing enqueued yet) is wiped and redone.
      def claim(batch)
        batch.reload
        if batch.receiving?
          batch.processing!
        elsif batch.processing? && batch.files_count.zero? && batch.import_items.where.not(status: %i[pending duplicate rejected]).none?
          batch.import_items.destroy_all
          batch.update!(error_message: nil)
        else
          return false
        end
        true
      end

      # True once every upload has been turned into items; false when it stopped part way.
      def expand(batch)
        pending = []
        archive = nil

        Dir.mktmpdir("certtrack-import-") do |dir|
          archive = Imports::Archive.new(dir)
          uploads = batch.uploads_attachments.includes(:blob).order(:id).to_a
          errors = []

          if (total = uploads.sum { |upload| upload.blob.byte_size }) > Imports::Config.max_batch_bytes
            errors << "The uploads add up to #{human_size(total)}, over the #{human_size(Imports::Config.max_batch_bytes)} " \
                      "batch limit: nothing was imported."
            uploads.each { |upload| record(batch, archive.not_examined(upload.filename.to_s), pending) }
          else
            uploads.each { |upload| expand_upload(batch, upload, archive, dir, pending) }
          end

          errors << archive.limit_message
          errors << nothing_found_message(archive) if archive.entries_seen.zero?
          batch.update!(files_count: archive.entries_seen, error_message: errors.compact.join(" ").presence)
        end
        true
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { import_batch_id: batch.id })
        message = "Unpacking stopped unexpectedly (#{error.class.name}). Files not listed here were not imported."
        batch.update_columns(files_count: archive&.entries_seen.to_i, updated_at: Time.current,
          error_message: [ batch.error_message, message ].compact.join(" "))
        false
      ensure
        # Even after an error: the items already made must still be read.
        ActiveJob.perform_all_later(pending.map { |item| Imports::ExtractTextJob.new(item) }) if pending&.any?
        batch.check_completion!
      end

      def expand_upload(batch, upload, archive, dir, pending)
        name = upload.filename.to_s
        return record(batch, archive.not_examined(name), pending) if archive.limit_reached?

        upload.blob.open(tmpdir: dir) do |file|
          archive.expand(file.path, name: name) do |entry|
            record(batch, entry, pending, upload_blob: entry.from_zip ? nil : upload.blob)
          end
        end
      rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError => error
        reason = error.is_a?(ActiveStorage::IntegrityError) ? "the stored copy is corrupt" : "the stored copy is missing"
        record(batch, archive.not_examined(name).with(rejection_reason: "Couldn't read this upload: #{reason}"), pending)
      end

      # Creates the item for one Archive::Entry; pending items are collected for extraction.
      def record(batch, entry, pending, upload_blob: nil)
        if entry.rejected?
          batch.import_items.create!(status: :rejected, original_filename: entry.name, sha256: entry.sha256,
            rejection_reason: entry.rejection_reason)
          return
        end

        original = ImportItem.original_file_for(entry.sha256)
        return create_duplicate(batch, entry, original) if original

        blob = file_blob(entry, upload_blob)
        item = with_file_lock(entry.sha256) do
          original = ImportItem.original_file_for(entry.sha256) # another batch may have just made it
          next create_duplicate(batch, entry, original) if original

          batch.import_items.create!(status: :pending, original_filename: entry.name, sha256: entry.sha256, file: blob)
        end

        if item.pending?
          pending << item
        elsif blob != upload_blob # the upload's own blob goes with the uploads (discard_uploads!)
          blob.purge_later
        end
      end

      def create_duplicate(batch, entry, original)
        batch.import_items.create!(status: :duplicate, original_filename: entry.name, sha256: entry.sha256,
          duplicate_of: original)
      end

      # The upload's own blob when the upload is the file (and its type was right);
      # otherwise a new blob with the entry's bytes.
      def file_blob(entry, upload_blob)
        return upload_blob if upload_blob && upload_blob.content_type == entry.content_type

        File.open(entry.path, "rb") do |io|
          ActiveStorage::Blob.create_and_upload!(io: io, filename: entry.filename, content_type: entry.content_type,
            identify: false)
        end
      end

      # Serializes item creation per file across concurrent batches, so two uploads of the
      # same bytes can't both become originals.
      def with_file_lock(sha256, &block)
        ImportItem.transaction do
          ImportItem.with_connection { |connection| connection.execute("SELECT pg_advisory_xact_lock(#{sha256.first(15).to_i(16)})") }
          block.call
        end
      end

      # Held while unpacking, so a second copy of this job can't run alongside; a worker
      # that dies loses its connection and with it the lock.
      def with_batch_lock(batch)
        key = "#{LOCK_NAMESPACE}, #{batch.id.to_i % (2**31)}"
        ImportBatch.with_connection do |connection|
          next unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")

          begin
            yield
          ensure
            connection.select_value("SELECT pg_advisory_unlock(#{key})")
          end
        end
      end

      def nothing_found_message(archive)
        skipped = archive.skipped.size
        note = skipped.zero? ? "" : " (only #{skipped} system or hidden #{"file".pluralize(skipped)} such as .DS_Store, skipped)"
        "Nothing to import: no files were found#{note}."
      end

      def human_size(bytes)
        ActiveSupport::NumberHelper.number_to_human_size(bytes)
      end
  end
end
