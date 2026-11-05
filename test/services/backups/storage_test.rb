require "test_helper"
require_relative "backups_test_support"

class Backups::StorageTest < ActiveSupport::TestCase
  include BackupsTestSupport

  test "key_for embeds a fixed-width UTC timestamp" do
    denver_evening = Time.find_zone!("America/Denver").local(2026, 11, 2, 20, 5, 9)

    key = Backups::Storage.key_for(denver_evening)

    assert_equal "db/cert_track-20261103T030509Z.sql.gz.enc", key
    assert_match Backups::Storage::KEY_PATTERN, key
  end

  test "taken_at reads the time back from a key, in Denver time" do
    taken = Backups::Storage.taken_at("db/cert_track-20261103T030509Z.sql.gz.enc")

    assert_equal Time.find_zone!("America/Denver").local(2026, 11, 2, 20, 5, 9), taken
    assert_equal "America/Denver", taken.time_zone.name
    assert_nil Backups::Storage.taken_at("db/notes.txt")
  end

  test "keeps the owner's 30 nightly backups, at least as many as the file-copy trash keeps days" do
    assert_equal 30, Backups::Storage::DEFAULT_KEEP
    assert_operator Backups::Storage::DEFAULT_KEEP, :>=, Backups::FileCopyStore::TRASH_DAYS
  end

  test "prune keeps exactly the DEFAULT_KEEP newest backups and leaves foreign objects alone" do
    keys = backup_keys(Backups::Storage::DEFAULT_KEEP + 6)
    client = stub_s3_client(list_objects_v2: list_response(keys.shuffle + [ "db/README.txt", "db/manual.sql" ]))
    storage = Backups::Storage.new(client:, bucket: "certtrack-backups")

    deleted = storage.prune

    assert_equal keys.first(6).reverse, deleted
    assert_equal keys.first(6).sort, deleted_keys(client).sort
    assert(deleted_requests(client).all? { |request| request[:params][:bucket] == "certtrack-backups" })
  end

  test "prune deletes nothing when DEFAULT_KEEP or fewer backups exist" do
    client = stub_s3_client(list_objects_v2: list_response(backup_keys(Backups::Storage::DEFAULT_KEEP)))

    assert_empty Backups::Storage.new(client:, bucket: "b").prune
    assert_empty deleted_keys(client)
  end

  test "prune honours a custom keep count" do
    keys = backup_keys(5)
    client = stub_s3_client(list_objects_v2: list_response(keys))

    Backups::Storage.new(client:, bucket: "b").prune(keep: 2)

    assert_equal keys.first(3).sort, deleted_keys(client).sort
  end

  test "backup_keys follows pagination and sorts oldest first" do
    keys = backup_keys(4)
    client = stub_s3_client(list_objects_v2: [
      { contents: [ { key: keys[3] }, { key: keys[1] } ], is_truncated: true, next_continuation_token: "page-2" },
      { contents: [ { key: keys[0] }, { key: keys[2] } ], is_truncated: false }
    ])
    storage = Backups::Storage.new(client:, bucket: "b")

    assert_equal keys, storage.backup_keys
    assert_equal [ nil, "page-2" ], list_requests(client).map { |request| request[:params][:continuation_token] }
    assert(list_requests(client).all? { |request| request[:params][:prefix] == "db/" })
  end

  test "latest_key is the newest backup, or nil when there are none" do
    keys = backup_keys(3)

    assert_equal keys.last, Backups::Storage.new(client: stub_s3_client(list_objects_v2: list_response(keys.shuffle)), bucket: "b").latest_key
    assert_nil Backups::Storage.new(client: stub_s3_client, bucket: "b").latest_key
  end

  test "upload streams the file to the bucket" do
    uploads = {}
    storage = Backups::Storage.new(client: stub_s3_client(uploads:), bucket: "b")

    Tempfile.create("backup") do |file|
      file.binmode
      file.write("ciphertext\x00\xFF".b)
      file.flush
      storage.upload("db/cert_track-20261102T100000Z.sql.gz.enc", file.path)
    end

    assert_equal({ "db/cert_track-20261102T100000Z.sql.gz.enc" => "ciphertext\x00\xFF".b }, uploads)
  end

  test "download writes the object to a path" do
    client = stub_s3_client(get_object: { body: "encrypted-bytes" })

    Dir.mktmpdir do |dir|
      path = Backups::Storage.new(client:, bucket: "b").download("db/x", File.join(dir, "x"))

      assert_equal "encrypted-bytes", File.binread(path)
    end
  end

  test "build_client points at the account's R2 endpoint with R2-compatible checksums" do
    with_stubbed_r2({}) do
      config = Backups::Storage.build_client.config

      assert_equal "https://test-account.r2.cloudflarestorage.com", config.endpoint.to_s
      assert_equal "auto", config.region
      assert_equal "when_required", config.request_checksum_calculation
      assert_equal "when_required", config.response_checksum_validation
      assert_equal "certtrack-backups-test", Backups::Storage.new.bucket
    end
  end

  test "requires R2_BACKUP_BUCKET when no bucket is given" do
    with_env("R2_BACKUP_BUCKET" => nil) do
      assert_raises(KeyError) { Backups::Storage.new(client: stub_s3_client) }
    end
  end

  private
    def backup_keys(count)
      start = Time.utc(2026, 10, 1, 9, 0, 0)
      Array.new(count) { |day| Backups::Storage.key_for(start + day.days) }
    end

    def deleted_requests(client)
      client.api_requests.select { |request| request[:operation_name] == :delete_object }
    end

    def deleted_keys(client)
      deleted_requests(client).map { |request| request[:params][:key] }
    end

    def list_requests(client)
      client.api_requests.select { |request| request[:operation_name] == :list_objects_v2 }
    end
end
