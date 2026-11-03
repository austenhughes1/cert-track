require "test_helper"
require_relative "backups_test_support"

class Backups::CreateTest < ActiveSupport::TestCase
  include BackupsTestSupport

  # A private TMPDIR per test: parallel workers share /tmp, so a global glob would see their dirs.
  setup do
    @previous_tmpdir = ENV["TMPDIR"]
    @tmp_root = Dir.mktmpdir("cert_track-create-test")
    ENV["TMPDIR"] = @tmp_root
  end

  teardown do
    @previous_tmpdir.nil? ? ENV.delete("TMPDIR") : ENV["TMPDIR"] = @previous_tmpdir
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.directory?(@tmp_root)
  end

  FailingDump = Struct.new(:message) do
    def write_to(io)
      io.write("-- partial output\n")
      raise Backups::Dump::Error, message
    end
  end

  test "uploads an encrypted gzipped dump under a timestamped key, then prunes" do
    skip_unless_pg_tools
    uploads = {}
    old_keys = Array.new(14) { |day| Backups::Storage.key_for(Time.utc(2026, 10, 1, 9) + day.days) }
    client = stub_s3_client(uploads:)
    storage = Backups::Storage.new(client:, bucket: "b")

    result = travel_to(Time.utc(2026, 11, 2, 10, 0, 0)) do
      # The listing taken after upload includes the new backup plus 14 older ones.
      client.stub_responses(:list_objects_v2, list_response(old_keys + [ Backups::Storage.key_for(Time.current) ]))
      Backups::Create.new(storage:, encryptor: backup_encryptor).call
    end

    assert_equal "db/cert_track-20261102T100000Z.sql.gz.enc", result.key
    assert_equal [ result.key ], uploads.keys
    assert_equal uploads[result.key].bytesize, result.bytes
    assert_equal [ old_keys.first ], result.pruned_keys
    assert uploads[result.key].start_with?(Backups::Encryptor::MAGIC)
    assert_includes decrypt_and_gunzip(uploads[result.key]), "CREATE TABLE public.users"
  end

  test "a failed dump raises, uploads nothing, prunes nothing and leaves no temp files" do
    client = stub_s3_client
    storage = Backups::Storage.new(client:, bucket: "b")
    before = leftover_temp_dirs

    error = assert_raises(Backups::Dump::Error) do
      Backups::Create.new(storage:, encryptor: backup_encryptor, dump: FailingDump.new("pg_dump failed (exit 1)")).call
    end

    assert_equal "pg_dump failed (exit 1)", error.message
    assert_empty client.api_requests
    assert_equal before, leftover_temp_dirs
  end

  test "removes its temp dir after a successful upload" do
    skip_unless_pg_tools
    before = leftover_temp_dirs

    encrypted_backup_of_test_database

    assert_equal before, leftover_temp_dirs
  end

  private
    def leftover_temp_dirs
      assert_equal @tmp_root, Dir.tmpdir, "Dir.tmpdir must honour the per-test TMPDIR"
      Dir.glob(File.join(@tmp_root, "cert_track-backup*"))
    end
end
