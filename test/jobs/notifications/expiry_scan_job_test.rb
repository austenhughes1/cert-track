require "test_helper"
require "fugit"
require_relative "../../services/notifications/notifications_test_support"

class Notifications::ExpiryScanJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper
  include NotificationsTestSupport

  setup { ActionMailer::Base.deliveries.clear }

  test "sends the day's digests and crew notices" do
    result = nil
    assert_emails(3) { result = Notifications::ExpiryScanJob.perform_now }

    assert_equal 2, result.digests_sent
    assert_equal 1, result.crew_notices_sent
  end

  test "a second run the same day sends nothing" do
    Notifications::ExpiryScanJob.perform_now

    assert_no_emails { Notifications::ExpiryScanJob.perform_now }
  end

  test "raises after the run when an email failed, having sent the rest" do
    error = assert_raises(Notifications::ExpiryScanJob::DeliveryFailed) do
      with_failing_expiry_mailer(fail_for: ->(params) { params[:user] == users(:manager) }) do
        Notifications::ExpiryScanJob.perform_now
      end
    end

    assert_match "1 expiry email(s) failed", error.message
    assert_match "Errno::ECONNREFUSED", error.message
    assert_equal 2, ActionMailer::Base.deliveries.size

    ActionMailer::Base.deliveries.clear
    assert_emails(1) { Notifications::ExpiryScanJob.perform_now }
    assert_equal [ users(:manager).email_address ], ActionMailer::Base.deliveries.last.to
  end

  test "is scheduled daily at 6 a.m. Denver time in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "daily_expiry_scan")

    assert_equal "Notifications::ExpiryScanJob", entry["class"]
    cron = Fugit.parse(entry["schedule"])
    assert_kind_of Fugit::Cron, cron
    assert_equal "America/Denver", cron.timezone.name
    assert_equal Time.utc(2026, 11, 2, 13), cron.next_time(Time.utc(2026, 11, 2, 12)).to_t.utc # MST
    assert_equal Time.utc(2026, 7, 3, 12), cron.next_time(Time.utc(2026, 7, 2, 13)).to_t.utc # MDT
  end

  # Mirrors SolidQueue::RecurringTask's validations (its table lives in the queue database).
  test "the schedule passes Solid Queue's recurring task checks" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "daily_expiry_scan")

    assert_instance_of Fugit::Cron, Fugit.parse(entry["schedule"], multi: :fail)
    assert_equal Notifications::ExpiryScanJob, entry["class"].safe_constantize
  end

  test "enqueues on the default queue" do
    assert_enqueued_with(job: Notifications::ExpiryScanJob, queue: "default") { Notifications::ExpiryScanJob.perform_later }
  end
end
