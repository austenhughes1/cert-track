require "aws-sdk-s3"

module Backups
  # The private R2 bucket that holds encrypted database backups (R2_BACKUP_BUCKET).
  # Tests pass client: Aws::S3::Client.new(stub_responses: true).
  class Storage
    PREFIX = "db/".freeze
    KEY_PATTERN = %r{\Adb/cert_track-\d{8}T\d{6}Z\.sql\.gz\.enc\z}
    DEFAULT_KEEP = 14

    def self.build_client
      Aws::S3::Client.new(
        endpoint: "https://#{ENV.fetch("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com",
        region: "auto",
        access_key_id: ENV.fetch("R2_ACCESS_KEY_ID"),
        secret_access_key: ENV.fetch("R2_SECRET_ACCESS_KEY"),
        # R2 rejects the SDK's default streaming checksums.
        request_checksum_calculation: "when_required",
        response_checksum_validation: "when_required"
      )
    end

    # Keys embed a fixed-width UTC timestamp, so sorting them sorts by age.
    def self.key_for(time)
      "#{PREFIX}cert_track-#{time.utc.strftime("%Y%m%dT%H%M%SZ")}.sql.gz.enc"
    end

    # When the backup with key was taken, in the app's time zone; nil for a key not made by key_for.
    def self.taken_at(key)
      ActiveSupport::TimeZone["UTC"].strptime(key[/\d{8}T\d{6}/], "%Y%m%dT%H%M%S").in_time_zone if KEY_PATTERN.match?(key.to_s)
    end

    attr_reader :bucket, :client

    def initialize(client: nil, bucket: ENV.fetch("R2_BACKUP_BUCKET"))
      @client = client || self.class.build_client
      @bucket = bucket
    end

    def upload(key, path)
      File.open(path, "rb") do |file|
        client.put_object(bucket:, key:, body: file, content_type: "application/octet-stream")
      end
      key
    end

    def download(key, path)
      client.get_object(bucket:, key:, response_target: path)
      path
    end

    # Backup keys, oldest first. Objects under db/ that don't look like ours are ignored.
    def backup_keys
      client.list_objects_v2(bucket:, prefix: PREFIX)
        .flat_map { |page| page.contents.map(&:key) }
        .grep(KEY_PATTERN)
        .sort
    end

    def latest_key
      backup_keys.last
    end

    # Deletes all but the newest `keep` backups and returns the deleted keys.
    def prune(keep: DEFAULT_KEEP)
      stale = backup_keys.reverse.drop(keep)
      stale.each { |key| client.delete_object(bucket:, key:) }
      stale
    end
  end
end
