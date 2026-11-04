require "test_helper"
require_relative "file_copy_test_support"

class Backups::FileCopyStoreTest < ActiveSupport::TestCase
  include FileCopyTestSupport

  test "configured is nil while FILE_COPY_DIR is unset, else a store rooted there" do
    with_env("FILE_COPY_DIR" => nil) { assert_nil Backups::FileCopyStore.configured }
    with_env("FILE_COPY_DIR" => "") { assert_nil Backups::FileCopyStore.configured }

    with_copy_dir { assert_equal File.expand_path(@copy_dir), Backups::FileCopyStore.configured.root }
  end

  test "the file_copies storage service is a Disk service at FILE_COPY_DIR, else under tmp/" do
    service = ActiveStorage::Blob.services.fetch(:file_copies)

    assert_instance_of ActiveStorage::Service::DiskService, service
    assert_equal (ENV["FILE_COPY_DIR"].presence || Rails.root.join("tmp/file_copies")).to_s, service.root.to_s
  end

  test "check! names the setup step when the folder is missing" do
    store = Backups::FileCopyStore.new(File.join(@copy_dir, "not-mounted"))

    assert_equal :missing, store.problem
    error = assert_raises(Backups::FileCopyStore::DirectoryError) { store.check! }
    assert_includes error.message, "#{store.root} does not exist"
    assert_includes error.message, "sudo mkdir -p /var/lib/certtrack/file-copies && sudo chown 1000:1000 /var/lib/certtrack/file-copies"
    assert_includes error.message, %(docs/DEPLOY.md, "File copies")
  end

  test "check! names the setup step when the folder is read-only (Docker made it as root)" do
    skip "root can write anywhere" if Process.euid.zero?
    File.chmod(0o555, @copy_dir)

    assert_equal :not_writable, @store.problem
    error = assert_raises(Backups::FileCopyStore::DirectoryError) { @store.check! }
    assert_includes error.message, "can't be written by uid #{Process.euid}"
    assert_includes error.message, "sudo chown 1000:1000 /var/lib/certtrack/file-copies"
  end

  test "check! passes for a writable folder" do
    assert_nil @store.problem
    assert_nil @store.check!
  end

  test "the free-space reserve is the larger of 5 GB and 10% of the disk" do
    small = Backups::FileCopyStore::DiskSpace.new(total_bytes: 20.gigabytes, free_bytes: 6.gigabytes)
    large = Backups::FileCopyStore::DiskSpace.new(total_bytes: 200.gigabytes, free_bytes: 25.gigabytes)

    assert_equal 5.gigabytes, small.reserve_bytes
    assert small.room_for?(1.gigabyte)
    assert_not small.room_for?(1.gigabyte + 1)
    assert_equal 20.gigabytes, large.reserve_bytes
    assert large.room_for?(5.gigabytes)
    assert_not large.room_for?(5.gigabytes + 1)
    assert_not Backups::FileCopyStore::DiskSpace.new(total_bytes: 200.gigabytes, free_bytes: 19.gigabytes).room_for?(0)
    assert Backups::FileCopyStore::DiskSpace.new(total_bytes: 200.gigabytes, free_bytes: 19.gigabytes).low?
  end

  test "read_disk_space reads df for the folder's filesystem" do
    space = Backups::FileCopyStore.read_disk_space(@copy_dir)

    assert_operator space.total_bytes, :>, 0
    assert_operator space.free_bytes, :<=, space.total_bytes
    assert_equal 0, space.total_bytes % 1024
  end

  test "read_disk_space raises for a folder df can't read" do
    error = assert_raises(Backups::FileCopyStore::DirectoryError) do
      Backups::FileCopyStore.read_disk_space(File.join(@copy_dir, "missing"))
    end
    assert_match "Could not read free space", error.message
  end

  test "receive moves a finished download into place, readable by the app's user only" do
    path = @store.receive("abcdefkey") { |file| file.write("certificate bytes") }

    assert_equal File.join(@store.root, "ab/cd/abcdefkey"), path
    assert_equal "certificate bytes", File.binread(path)
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
    assert_empty Dir.children(File.join(@store.root, "incoming"))
  end

  test "receive leaves nothing behind when the block raises" do
    assert_raises(IOError) { @store.receive("abcdefkey") { |file| file.write("half"); raise IOError } }

    assert_not File.exist?(@store.path_for("abcdefkey"))
    assert_empty Dir.children(File.join(@store.root, "incoming"))
  end

  test "keys lists live copies only" do
    @store.receive("abcdefkey") { |file| file.write("x") }
    @store.receive("zyxwvukey") { |file| file.write("y") }
    @store.receive("trashedkey") { |file| file.write("z") }
    @store.move_to_trash("trashedkey", day: Date.new(2026, 11, 1))
    FileUtils.mkdir_p(File.join(@store.root, "incoming"))
    File.write(File.join(@store.root, "incoming", "partial"), "p")
    @store.write_status("outcome" => "complete")

    assert_equal %w[abcdefkey zyxwvukey], @store.keys.sort
    assert_equal %w[trashedkey], @store.trashed_keys
  end

  test "trashed_keys lists each copy in the trash once, from every day" do
    [ Date.new(2026, 10, 1), Date.new(2026, 11, 2) ].each do |day|
      %w[samekey otherkey].each do |key|
        @store.receive(key) { |file| file.write(key) }
        @store.move_to_trash(key, day:)
      end
    end
    @store.receive("livekey") { |file| file.write("x") }

    assert_equal %w[otherkey samekey], @store.trashed_keys.sort
  end

  test "trash days ignore folders that aren't dates" do
    %w[2026-10-01 2026-11-02 notes 2026-13-40].each { |name| FileUtils.mkdir_p(File.join(@store.root, "trash", name)) }

    assert_equal [ Date.new(2026, 10, 1), Date.new(2026, 11, 2) ], @store.trash_days
  end

  test "expire_trash deletes trash folders 30 or more days old" do
    { "old" => Date.new(2026, 10, 4), "kept" => Date.new(2026, 10, 5) }.each do |key, day|
      @store.receive("#{key}-key") { |file| file.write(key) }
      @store.move_to_trash("#{key}-key", day:)
    end

    assert_equal 1, @store.expire_trash(today: Date.new(2026, 11, 3))
    assert_equal [ Date.new(2026, 10, 5) ], @store.trash_days
    assert_equal [ 1, 4 ], @store.trash_usage
  end

  test "status round-trips, and a damaged status file reads as none" do
    assert_nil @store.read_status

    @store.write_status("outcome" => "complete", "copied" => 3)
    assert_equal({ "outcome" => "complete", "copied" => 3 }, @store.read_status)
    assert_equal [ "status.json" ], Dir.children(@store.root)

    File.write(File.join(@store.root, "status.json"), "{not json")
    assert_nil @store.read_status
  end
end
