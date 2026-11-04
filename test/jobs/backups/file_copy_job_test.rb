require "test_helper"
require "fugit"
require_relative "../../services/backups/file_copy_test_support"

class Backups::FileCopyJobTest < ActiveJob::TestCase
  include FileCopyTestSupport

  test "does nothing, and logs it, while FILE_COPY_DIR is unset" do
    certificate_blob
    log = StringIO.new

    result = with_env("FILE_COPY_DIR" => nil) { with_logger(log) { Backups::FileCopyJob.perform_now } }

    assert_nil result
    assert_includes log.string, "FILE_COPY_DIR is not set; skipping the nightly file copy"
    assert_empty Dir.children(@copy_dir)
  end

  test "copies new files into FILE_COPY_DIR" do
    blob = certificate_blob

    result = with_copy_dir { Backups::FileCopyJob.perform_now }

    assert_equal "complete", result.outcome
    assert_equal blob.download, copied_bytes(blob)
    assert_equal "complete", @store.read_status["outcome"]
  end

  test "fails, naming the setup step, when the folder is missing" do
    error = with_copy_dir(File.join(@copy_dir, "not-mounted")) do
      assert_raises(Backups::FileCopyStore::DirectoryError) { Backups::FileCopyJob.perform_now }
    end

    assert_includes error.message, Backups::FileCopyStore::SETUP_COMMAND
    assert_includes error.message, %(docs/DEPLOY.md, "File copies")
  end

  test "fails when the folder is read-only" do
    skip "root can write anywhere" if Process.euid.zero?
    File.chmod(0o555, @copy_dir)

    with_copy_dir do
      assert_raises(Backups::FileCopyStore::DirectoryError) { Backups::FileCopyJob.perform_now }
    end
  end

  test "is scheduled nightly at 4:15 a.m. Denver time in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "nightly_file_copy")

    assert_equal Backups::FileCopyJob, entry["class"].safe_constantize
    cron = Fugit.parse(entry["schedule"], multi: :fail)
    assert_equal "America/Denver", cron.timezone.name
    assert_equal Time.utc(2026, 11, 3, 11, 15), cron.next_time(Time.utc(2026, 11, 2, 12)).to_t.utc
  end

  test "enqueues on the default queue" do
    assert_enqueued_with(job: Backups::FileCopyJob, queue: "default") { Backups::FileCopyJob.perform_later }
  end

  private
    def with_logger(io)
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
    ensure
      Rails.logger = previous
    end
end
