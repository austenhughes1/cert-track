require "test_helper"

class Imports::SummaryDeliveryJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  MORNING = Time.zone.local(2026, 11, 3, 10, 0) # a Tuesday in Denver

  setup do
    ActionMailer::Base.deliveries.clear
    travel_to MORNING
    @batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing)
    @batch.import_items.create!(status: :accepted, sha256: SecureRandom.hex(32))
  end

  test "ImportMailer delivers through it, on the default queue" do
    assert_equal Imports::SummaryDeliveryJob, ImportMailer.delivery_job
    assert_enqueued_with(job: Imports::SummaryDeliveryJob, queue: "default") do
      ImportMailer.with(batch: @batch).summary.deliver_later
    end
  end

  test "a finished batch's summary counts as one of today's sends" do
    assert_emails(1) { perform_enqueued_jobs { @batch.check_completion! } }

    assert_equal 1, Notifications::SendBudget.sent_today
    assert_equal [ "manager@example.com" ], ActionMailer::Base.deliveries.last.to
  end

  test "past the daily email cap the summary waits for tomorrow morning, then goes out once" do
    Notifications::SendBudget.record!(Notifications::SendBudget.daily_limit)

    tomorrow_morning = Time.zone.local(2026, 11, 4, 7, 0)
    @batch.check_completion!
    assert_enqueued_with(job: Imports::SummaryDeliveryJob, at: tomorrow_morning) do
      perform_enqueued_jobs(only: Imports::SummaryDeliveryJob, at: Time.current)
    end
    assert_empty ActionMailer::Base.deliveries
    assert_equal 1, EmailSendDay.deferred_on(Date.current), "the dashboard banner counts it"
    assert_equal Notifications::SendBudget.daily_limit, Notifications::SendBudget.sent_today

    travel_to tomorrow_morning do
      perform_enqueued_jobs(only: Imports::SummaryDeliveryJob, at: Time.current)
      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal 1, Notifications::SendBudget.sent_today
      assert_includes ActionMailer::Base.deliveries.last.subject, "CertTrack import"
    end
    assert_no_enqueued_jobs(only: Imports::SummaryDeliveryJob)
    assert_no_enqueued_emails { @batch.check_completion! }
  end

  test "a failed delivery gives its send back and is raised for the jobs dashboard" do
    ActionMailer::Base.add_delivery_method(:smtp_that_fails, FailingDelivery)
    ImportMailer.delivery_method = :smtp_that_fails

    ImportMailer.with(batch: @batch).summary.deliver_later
    assert_raises(Net::SMTPServerBusy) { perform_enqueued_jobs(only: Imports::SummaryDeliveryJob) }

    assert_equal 0, Notifications::SendBudget.sent_today
  ensure
    ImportMailer.delivery_method = :test
  end

  test "a batch deleted before its summary went out is skipped" do
    ImportMailer.with(batch: @batch).summary.deliver_later
    @batch.destroy!

    assert_no_emails { perform_enqueued_jobs(only: Imports::SummaryDeliveryJob) }
    assert_equal 0, Notifications::SendBudget.sent_today
  end

  # A delivery method whose server refuses every message.
  class FailingDelivery
    def initialize(*) = nil

    def deliver!(_mail)
      raise Net::SMTPServerBusy, "421 try again later"
    end
  end
end
