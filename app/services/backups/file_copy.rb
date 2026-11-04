module Backups
  # The nightly second copy of the certificate files (Backups::FileCopyJob): copies every blob
  # worth keeping from its storage service (R2 in production) into the FileCopyStore on the VM's
  # own disk. R2 then covers losing the VM, and the copy covers a deleted file or losing the
  # Cloudflare account; certtrack:restore_files puts copies back.
  #
  # Only blobs without a copy are downloaded, once each: R2 reads count against its free
  # allowance. Each download streams to disk while its MD5 is checked against the blob's
  # checksum, and only a matching file is moved into place.
  #
  # A copy whose blob is gone (deleted, or no longer attached to anything kept) moves to the
  # trash, dated the day it was first found missing, and is deleted TRASH_DAYS later. A copy
  # whose blob is back (its row returned with a database restore) leaves the trash first, before
  # any of the trash expires. Only a database backup from before the delete still names a
  # deleted file, and those are kept 14 days (Backups::Storage::DEFAULT_KEEP): after that, its
  # copy in the trash can only be found by opening the files there (docs/DEPLOY.md, "Files
  # missing from R2"). Copying stops, and is reported, once free space would drop under the
  # store's reserve (the larger of 5 GB and 10% of the disk).
  class FileCopy
    class LowSpaceError < StandardError; end
    class CopyError < StandardError; end

    # Worth a second copy. Left out on purpose: variant and preview images (made again from their
    # file), packet zips (rebuilt on demand, deleted after 7 days) and an import's raw uploads
    # (unpacked into import items). Import items keep their file until they are accepted.
    KEPT_ATTACHMENTS = [
      { record_type: "Certificate", name: "files" },
      { record_type: "ImportItem", name: "file" },
      { name: "index_pdf" } # PacketBuild#index_pdf; by name alone, so it still matches if it moves
    ].freeze
    # A source that fails this many blobs in a row (R2 down, wrong keys) ends the run early.
    MAX_FAILURES_IN_A_ROW = 20
    ERRORS_KEPT = 10

    Result = Data.define(:outcome, :kept, :copied, :copied_bytes, :untrashed, :failed, :not_copied,
      :trashed, :expired, :errors, :disk_space) do
      def complete? = outcome == "complete"
      def low_space? = outcome == "low_space"
    end

    def self.kept_blobs
      attachments = KEPT_ATTACHMENTS.map { |match| ActiveStorage::Attachment.where(match) }.reduce(:or)
      ActiveStorage::Blob.where(id: attachments.select(:blob_id))
    end

    attr_reader :store

    def initialize(store:, today: Date.current)
      @store = store
      @today = today
    end

    def call
      store.check!
      store.with_lock do
        reset_counts
        store.clear_incoming
        kept = self.class.kept_blobs.pluck(:key).to_set
        @trashed = trash_copies_not_in(kept)
        @untrashed = untrash_copies_in(kept)
        @expired = store.expire_trash(today: @today)
        copy_missing(store.disk_space)
        finish(kept.size)
      end
    end

    private
      def reset_counts
        @present = @copied = @copied_bytes = @failed = 0
        @errors = []
        @stopped_for_space = false
      end

      def trash_copies_not_in(kept)
        store.keys.reject { |key| kept.include?(key) }.each { |key| store.move_to_trash(key, day: @today) }.size
      end

      # Moves the trashed copies of kept blobs back into place, with no download.
      def untrash_copies_in(kept)
        returned = store.trashed_keys.select { |key| kept.include?(key) }
        return 0 if returned.empty?

        self.class.kept_blobs.where(key: returned).to_a.count { |blob| !store.copied?(blob) && store.untrash(blob) }
      end

      def copy_missing(space)
        failures_in_a_row = 0

        self.class.kept_blobs.find_each do |blob|
          if store.copied?(blob)
            @present += 1
          elsif !space.room_for?(@copied_bytes + blob.byte_size)
            @stopped_for_space = true
            break
          else
            copy(blob)
            @present += 1
            @copied += 1
            @copied_bytes += blob.byte_size
          end
          failures_in_a_row = 0
        rescue Errno::ENOSPC, Errno::EDQUOT
          @stopped_for_space = true
          break
        rescue StandardError => error
          record_failure(blob, error)
          failures_in_a_row += 1
          break if failures_in_a_row >= MAX_FAILURES_IN_A_ROW
        end
      end

      # Streams blob into incoming/ (the S3 service fetches 5 MB ranges), checking its size and MD5.
      def copy(blob)
        store.receive(blob.key) do |file|
          digest = OpenSSL::Digest::MD5.new
          bytes = 0
          blob.service.download(blob.key) do |chunk|
            digest << chunk
            bytes += chunk.bytesize
            file.write(chunk)
          end

          unless bytes == blob.byte_size && (blob.checksum.nil? || digest.base64digest == blob.checksum)
            raise ActiveStorage::IntegrityError, "storage returned #{bytes} bytes with MD5 #{digest.base64digest}; " \
              "the blob has #{blob.byte_size} bytes with MD5 #{blob.checksum}"
          end
        end
      end

      def record_failure(blob, error)
        @failed += 1
        message = "blob #{blob.id} (#{blob.key}): #{error.class.name}: #{error.message}".truncate(300)
        @errors << message if @errors.size < ERRORS_KEPT
        Rails.logger.warn("[Backups] file copy failed for #{message}")
      end

      def finish(kept_count)
        outcome = if @stopped_for_space then "low_space"
        elsif @failed.positive? then "incomplete"
        else "complete"
        end
        space = store.disk_space
        result = Result.new(outcome:, kept: kept_count, copied: @copied, copied_bytes: @copied_bytes,
          untrashed: @untrashed, failed: @failed, not_copied: [ kept_count - @present, 0 ].max,
          trashed: @trashed, expired: @expired, errors: @errors, disk_space: space)

        write_status(result)
        report(result)
        Rails.logger.info("[Backups] file copy #{outcome}: #{result.copied} copied (#{result.copied_bytes} bytes), " \
          "#{result.untrashed} back from trash, #{result.failed} failed, #{result.not_copied} not copied, " \
          "#{result.trashed} moved to trash, #{result.expired} expired from trash")
        result
      end

      def write_status(result)
        now = Time.current
        last_success_at = result.complete? ? now.utc.iso8601 : store.read_status&.dig("last_success_at")
        store.write_status(
          "finished_at" => now.utc.iso8601, "outcome" => result.outcome, "last_success_at" => last_success_at,
          "kept" => result.kept, "copied" => result.copied, "copied_bytes" => result.copied_bytes,
          "untrashed" => result.untrashed, "failed" => result.failed, "not_copied" => result.not_copied,
          "trashed" => result.trashed, "expired" => result.expired, "errors" => result.errors,
          "free_bytes" => result.disk_space.free_bytes, "total_bytes" => result.disk_space.total_bytes,
          "reserve_bytes" => result.disk_space.reserve_bytes
        )
      end

      def report(result)
        if result.low_space?
          space = result.disk_space
          Rails.error.report(LowSpaceError.new(
            "Stopped copying certificate files to #{store.root}: #{space.free_bytes} bytes free, under the " \
            "#{space.reserve_bytes}-byte reserve; #{result.not_copied} file(s) not copied"
          ), handled: true, severity: :error, source: "backups.file_copy")
        end
        return if result.failed.zero?

        Rails.error.report(CopyError.new("#{result.failed} certificate file(s) could not be copied to #{store.root}: " \
          "#{result.errors.first(3).join("; ")}"), handled: true, source: "backups.file_copy")
      end
  end
end
