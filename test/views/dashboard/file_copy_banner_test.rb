require "test_helper"
require_relative "../../services/backups/file_copy_test_support"

class DashboardFileCopyBannerTest < ActionView::TestCase
  include FileCopyTestSupport

  setup { travel_to Time.zone.local(2026, 11, 4, 9, 0) }

  test "renders nothing while copies are off" do
    with_env("FILE_COPY_DIR" => nil) do
      assert_equal "", render(partial: "dashboard/file_copy_banner").strip
    end
  end

  test "renders nothing after a recent complete copy" do
    record_run(finished_at: 5.hours.ago, outcome: "complete")

    assert_equal "", render_banner.strip
  end

  test "names the setup command when the folder is missing" do
    with_copy_dir(File.join(@copy_dir, "not-mounted")) { render partial: "dashboard/file_copy_banner" }

    assert_select "#file_copy_banner.bg-amber-50[role=status]" do
      assert_select "p", text: "Certificate files are not being copied to the server"
      assert_select "p", text: /The server folder for the nightly copy is missing/
      assert_select "code", text: Backups::FileCopyStore::SETUP_COMMAND
      assert_select "p", text: /No complete copy yet\./
    end
  end

  test "says when the folder can't be written to" do
    skip "root can write anywhere" if Process.euid.zero?
    File.chmod(0o555, @copy_dir)

    render_banner

    assert_select "#file_copy_banner p", text: /The server folder for the nightly copy can't be written to/
  end

  test "warns that the disk is almost full and how many files wait" do
    record_run(finished_at: 5.hours.ago, outcome: "low_space", last_success_at: 3.days.ago, not_copied: 12,
      free_bytes: 9.gigabytes, reserve_bytes: 10.gigabytes)

    render_banner

    assert_select "#file_copy_banner" do
      assert_select "p", text: "Server disk almost full"
      assert_select "p", text: /9 GB of 100 GB is free\.\s+The nightly copy of certificate files stops below 10 GB free, to leave room for the database,\s+so 12 files are not copied yet\./
      assert_select "p", text: /Last complete copy: Nov 1, 2026 9:00 AM\s+\(3 days ago\)\./
      assert_select "time[datetime=?]", 3.days.ago.iso8601
    end
  end

  test "says when the copy is behind because files failed" do
    record_run(finished_at: 5.hours.ago, outcome: "incomplete", last_success_at: 2.days.ago - 1.hour, failed: 2)

    render_banner

    assert_select "#file_copy_banner" do
      assert_select "p", text: "Nightly file copy is behind"
      assert_select "p", text: /The last run could not copy 2 files\./
      assert_select "code", text: "bin/rails certtrack:file_copy_status"
      assert_select "p", text: /Last complete copy: Nov 2, 2026 8:00 AM/
    end
  end

  test "says when the copy hasn't run to the end lately" do
    record_run(finished_at: 3.days.ago, outcome: "complete")

    render_banner

    assert_select "#file_copy_banner p", text: /The copy has not run to the end since Nov 1, 2026 9:00 AM;\s+check Jobs for errors\./
    assert_select "#file_copy_banner a[href='/jobs']", text: "Jobs"
  end

  private
    def render_banner
      with_copy_dir { render partial: "dashboard/file_copy_banner" }
    end
end
