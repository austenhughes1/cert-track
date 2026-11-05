require "test_helper"
require "fugit"
require_relative "../../services/backups/backups_test_support"

class Backups::DatabaseJobTest < ActiveJob::TestCase
  include BackupsTestSupport

  test "dumps the real test database, encrypts it, uploads it to R2 and prunes to DEFAULT_KEEP" do
    skip_unless_pg_tools
    uploads = {}
    deleted = []
    old_keys = Array.new(Backups::Storage::DEFAULT_KEEP + 2) { |day| Backups::Storage.key_for(Time.utc(2026, 10, 1, 9) + day.days) }
    stubs = {
      put_object: capture_upload(uploads),
      list_objects_v2: ->(_context) { list_response(old_keys + uploads.keys) },
      delete_object: ->(context) { deleted << context.params[:key]; {} }
    }

    key = with_backup_key { with_stubbed_r2(stubs) { Backups::DatabaseJob.perform_now } }

    assert_match Backups::Storage::KEY_PATTERN, key
    assert_equal [ key ], uploads.keys
    sql = decrypt_and_gunzip(uploads.fetch(key))
    assert_includes sql, "CREATE TABLE public.users"
    assert_includes sql, users(:viewer).email_address
    assert_equal old_keys.first(3).sort, deleted.sort
  end

  test "raises when pg_dump exits non-zero so Solid Queue records the failure" do
    uploads = {}

    error = Dir.mktmpdir do |bin|
      File.write(File.join(bin, "pg_dump"), "#!/bin/sh\necho 'pg_dump: error: connection refused' >&2\nexit 1\n")
      File.chmod(0o755, File.join(bin, "pg_dump"))

      with_env("PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV["PATH"]}") do
        with_backup_key do
          with_stubbed_r2(put_object: capture_upload(uploads)) do
            assert_raises(Backups::Dump::Error) { Backups::DatabaseJob.perform_now }
          end
        end
      end
    end

    assert_match "connection refused", error.message
    assert_empty uploads
  end

  test "fails before dumping when the backup key is not configured" do
    with_backup_key(nil) do
      with_stubbed_r2({}) do
        assert_raises(Backups::Encryptor::InvalidKeyError) { Backups::DatabaseJob.perform_now }
      end
    end
  end

  test "is scheduled nightly at 3 a.m. Denver time in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "nightly_database_backup")

    assert_equal "Backups::DatabaseJob", entry["class"]
    cron = Fugit.parse(entry["schedule"])
    assert_equal "America/Denver", cron.timezone.name
    assert_equal Time.utc(2026, 11, 3, 10), cron.next_time(Time.utc(2026, 11, 2, 12)).to_t.utc
    assert_equal Time.utc(2026, 7, 3, 9), cron.next_time(Time.utc(2026, 7, 2, 12)).to_t.utc
  end

  test "enqueues on the default queue" do
    assert_enqueued_with(job: Backups::DatabaseJob, queue: "default") { Backups::DatabaseJob.perform_later }
  end
end
