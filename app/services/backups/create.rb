require "zlib"

module Backups
  # pg_dump -> gzip -> AES-256-GCM -> temp file -> R2, then prune to the newest 30 (Storage::DEFAULT_KEEP).
  # Only ciphertext touches disk; the temp dir is removed even when a step fails.
  class Create
    Result = Data.define(:key, :bytes, :pruned_keys)

    def initialize(storage: nil, encryptor: nil, dump: nil, keep: Storage::DEFAULT_KEEP)
      @storage = storage
      @encryptor = encryptor
      @dump = dump
      @keep = keep
    end

    def call
      key = Storage.key_for(Time.current)

      bytes = Dir.mktmpdir("cert_track-backup") do |dir|
        path = File.join(dir, File.basename(key))
        File.open(path, "wb") { |file| encryptor.encrypt(file) { |sink| compress_dump_into(sink) } }
        storage.upload(key, path)
        File.size(path)
      end

      pruned = storage.prune(keep: @keep)
      Rails.logger.info("[Backups] uploaded #{key} (#{bytes} bytes), pruned #{pruned.size} old backup(s)")
      Result.new(key:, bytes:, pruned_keys: pruned)
    end

    private
      def compress_dump_into(sink)
        gzip = Zlib::GzipWriter.new(sink)
        dump.write_to(gzip)
      ensure
        gzip&.finish
      end

      def storage = @storage ||= Storage.new
      def encryptor = @encryptor ||= Encryptor.new
      def dump = @dump ||= Dump.new
  end
end
