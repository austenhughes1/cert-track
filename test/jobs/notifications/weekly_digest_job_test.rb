require "test_helper"
require "fugit"
require_relative "../../services/notifications/notifications_test_support"

class Notifications::WeeklyDigestJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper
  include NotificationsTestSupport

  MONDAY = Time.zone.local(2026, 11, 2, 6, 0)

  setup { ActionMailer::Base.deliveries.clear }

  test "sends every digest recipient a weekly digest of expiring certificates and project gaps" do
    sent = nil
    assert_emails(2) { sent = Notifications::WeeklyDigestJob.perform_now }

    assert_equal 2, sent
    assert_equal digest_recipient_emails.sort, ActionMailer::Base.deliveries.flat_map(&:to).sort
    body = ActionMailer::Base.deliveries.first.text_part.decoded

    # Expiring within 30 days, expired included; Juan's first aid (~60 days) is not listed.
    expiring = body[/EXPIRING WITHIN 30 DAYS(.*)GAPS ON ACTIVE PROJECTS/m, 1]
    assert_includes expiring, "Juan Ortiz, Flagger"
    assert_includes expiring, "Dave Miller, CDL"
    assert_includes expiring, "Mari Garcia, First Aid"
    assert_includes expiring, "Li Chen, First Aid"
    assert_not_includes expiring, "Juan Ortiz, First Aid"
    assert_not_includes expiring, "Sam Price", "inactive crew"

    # Missing and expired requirements on the active project; the closed project is left out.
    gaps = body[/GAPS ON ACTIVE PROJECTS(.*)/m, 1]
    assert_includes gaps, "2417"
    assert_includes gaps, "Mari Garcia, Flagger: Missing"
    assert_includes gaps, "Li Chen, Authorized Climber: Missing"
    assert_includes gaps, "Dave Miller, First Aid"
    assert_not_includes gaps, "2390"
  end

  test "is sent even when there is nothing to report" do
    deactivate_fixture_crew!

    assert_emails(2) { Notifications::WeeklyDigestJob.perform_now }
    assert ActionMailer::Base.deliveries.all? { |mail| mail.subject == "CertTrack weekly: all clear" }
  end

  test "does not touch the daily send log" do
    assert_no_difference(-> { ExpiryNotification.count }) { Notifications::WeeklyDigestJob.perform_now }
  end

  test "counts each email against the daily cap" do
    travel_to MONDAY
    Notifications::WeeklyDigestJob.perform_now

    assert_equal 2, Notifications::SendBudget.sent_today
  end

  test "recipients past the cap are deferred and retried the next morning after the daily scan" do
    travel_to MONDAY
    Notifications::SendBudget.record!(Notifications::SendBudget.daily_limit - 1)
    first, second = User.digest_recipients.order(:id).to_a

    assert_emails(1) do
      assert_enqueued_with(job: Notifications::WeeklyDigestJob, args: [ [ second.id ] ],
        at: Time.zone.local(2026, 11, 3, 6, 30)) do
        assert_equal 1, Notifications::WeeklyDigestJob.perform_now
      end
    end
    assert_equal [ first.email_address ], ActionMailer::Base.deliveries.last.to
    assert_equal 1, EmailSendDay.deferred_on(Date.current)

    travel_to Time.zone.local(2026, 11, 3, 6, 30)
    ActionMailer::Base.deliveries.clear
    assert_emails(1) { perform_enqueued_jobs(only: Notifications::WeeklyDigestJob) }
    assert_equal [ second.email_address ], ActionMailer::Base.deliveries.last.to
  end

  test "a deferral is not retried when the next day is Monday" do
    travel_to Time.zone.local(2026, 11, 8, 6, 30) # Sunday
    Notifications::SendBudget.record!(Notifications::SendBudget.daily_limit)

    assert_no_emails do
      assert_no_enqueued_jobs { Notifications::WeeklyDigestJob.perform_now([ users(:admin).id ]) }
    end
  end

  test "recipient_ids limits the run to those digest recipients" do
    assert_emails(1) { Notifications::WeeklyDigestJob.perform_now([ users(:manager).id, users(:viewer).id ]) }

    assert_equal [ users(:manager).email_address ], ActionMailer::Base.deliveries.last.to
  end

  test "a failed send is reported and skipped, not retried for everyone" do
    sent = nil
    with_failing_expiry_mailer(fail_for: ->(params) { params[:user] == users(:admin) }) do
      assert_nothing_raised { sent = Notifications::WeeklyDigestJob.perform_now }
    end

    assert_equal 1, sent
    assert_equal [ users(:manager).email_address ], ActionMailer::Base.deliveries.flat_map(&:to)
    assert_equal 1, Notifications::SendBudget.sent_today, "the failed send handed its reservation back"
  end

  test "does nothing without digest recipients" do
    User.update_all(receives_digest: false)

    assert_no_emails { assert_equal 0, Notifications::WeeklyDigestJob.perform_now }
  end

  test "is scheduled Mondays at 6 a.m. Denver time in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "weekly_expiry_digest")

    assert_equal "Notifications::WeeklyDigestJob", entry["class"]
    cron = Fugit.parse(entry["schedule"])
    assert_equal "America/Denver", cron.timezone.name
    # From Tuesday Nov 3, 2026 the next run is Monday Nov 9, 6:00 MST.
    assert_equal Time.utc(2026, 11, 9, 13), cron.next_time(Time.utc(2026, 11, 3, 12)).to_t.utc
    assert_instance_of Fugit::Cron, Fugit.parse(entry["schedule"], multi: :fail) # Solid Queue's own check
  end
end
