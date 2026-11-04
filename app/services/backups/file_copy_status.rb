module Backups
  # The nightly file copy as admins see it (the dashboard banner, certtrack:file_copy_status):
  # the last run Backups::FileCopy recorded in the store's status.json, plus a live check that
  # the folder is there and writable. Says nothing while copies are off (FILE_COPY_DIR unset).
  class FileCopyStatus
    STALE_AFTER = 2.days

    Inventory = Data.define(:kept, :kept_bytes, :copied, :copied_bytes, :trash_files, :trash_bytes, :trash_days)

    attr_reader :store

    def self.current(now: Time.current)
      new(FileCopyStore.configured, now:)
    end

    def initialize(store, now: Time.current)
      @store = store
      @now = now
    end

    def configured?
      store.present?
    end

    # :missing, :not_writable or nil (see FileCopyStore#problem).
    def folder_problem
      return @folder_problem if defined?(@folder_problem)

      @folder_problem = store&.problem
    end

    # The last run's status.json (string keys), or nil before the first run.
    def last_run
      return @last_run if defined?(@last_run)

      @last_run = (store.read_status if configured? && folder_problem != :missing)
    end

    def last_run_at = time_at("finished_at")
    def last_success_at = time_at("last_success_at")
    def not_copied = last_run&.dig("not_copied").to_i
    def failed = last_run&.dig("failed").to_i
    def free_bytes = last_run&.dig("free_bytes").to_i
    def total_bytes = last_run&.dig("total_bytes").to_i
    def reserve_bytes = last_run&.dig("reserve_bytes").to_i

    # The last run stopped for space, or ended with the disk under the reserve.
    def low_space?
      return false unless last_run

      last_run["outcome"] == "low_space" || free_bytes < reserve_bytes
    end

    # A run happened, but no complete copy finished in the last STALE_AFTER.
    def stale?
      last_run.present? && (last_success_at.nil? || last_success_at < @now - STALE_AFTER)
    end

    def needs_attention?
      configured? && (folder_problem.present? || low_space? || stale?)
    end

    # Counts from the database and the folder, without reading storage.
    def inventory
      kept = kept_bytes = copied = copied_bytes = 0
      FileCopy.kept_blobs.find_each do |blob|
        kept += 1
        kept_bytes += blob.byte_size
        next unless store.copied?(blob)

        copied += 1
        copied_bytes += blob.byte_size
      end
      trash_files, trash_bytes = store.trash_usage

      Inventory.new(kept:, kept_bytes:, copied:, copied_bytes:, trash_files:, trash_bytes:, trash_days: store.trash_days)
    end

    private
      def time_at(field)
        value = last_run&.dig(field)
        Time.iso8601(value).in_time_zone if value.is_a?(String)
      rescue ArgumentError
        nil
      end
  end
end
