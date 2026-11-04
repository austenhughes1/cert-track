require "test_helper"
require_relative "notifications_test_support"

class Notifications::ExpiryScanTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include NotificationsTestSupport

  CREW_EMAIL = "pat.tester@example.com".freeze

  setup { ActionMailer::Base.deliveries.clear }

  # --- Phase 2 acceptance -------------------------------------------------------------

  test "daily runs from 95 days out to past expiry send d90, d60, d30, d7 and expired exactly once each" do
    deactivate_fixture_crew!
    start = Time.zone.local(2027, 1, 4, 6, 0)
    travel_to start
    member = create_crew_member(email: CREW_EMAIL, expiry_emails_opt_in: true)
    certificate = create_certificate(member, expires_on: Date.current + 95)

    sent_on_days_left = Hash.new { |hash, email| hash[email] = [] }
    (0..100).each do |offset|
      travel_to start + offset.days
      ActionMailer::Base.deliveries.clear
      Notifications::ExpiryScan.call
      ActionMailer::Base.deliveries.each { |mail| sent_on_days_left[mail.to.first] << 95 - offset }
    end

    digest_recipient_emails.each do |email|
      assert_equal [ 90, 60, 30, 7, -1 ], sent_on_days_left[email], "digests to #{email}"
      assert_equal %w[d90 d60 d30 d7 expired], logged_thresholds(certificate, email)
    end
    assert_equal [ 30, 7 ], sent_on_days_left[CREW_EMAIL], "crew notices"
    assert_equal %w[d30 d7], logged_thresholds(certificate, CREW_EMAIL)
    assert_equal (digest_recipient_emails + [ CREW_EMAIL ]).sort, sent_on_days_left.keys.sort
    assert ExpiryNotification.where(certificate: certificate).all?(&:sent_at), "every log row is stamped sent"
  end

  test "a same-day re-run sends nothing" do
    travel_to Time.current.change(hour: 6)
    assert_emails(3) { Notifications::ExpiryScan.call }

    assert_no_emails do
      assert_no_difference -> { ExpiryNotification.count } do
        result = Notifications::ExpiryScan.call
        assert_equal 0, result.items_sent
      end
    end
  end

  test "a missed week sends only the most urgent unsent threshold" do
    deactivate_fixture_crew!
    travel_to Time.zone.local(2027, 3, 1, 6, 0)
    certificate = create_certificate(create_crew_member, expires_on: Date.current + 35)
    Notifications::ExpiryScan.call

    travel 30.days # 5 days left: d30 was skipped while nothing ran
    ActionMailer::Base.deliveries.clear
    assert_emails(digest_recipient_emails.size) { Notifications::ExpiryScan.call }

    ActionMailer::Base.deliveries.each do |mail|
      assert_includes mail.text_part.decoded, "[7 days]"
      assert_not_includes mail.text_part.decoded, "[30 days]"
    end
    digest_recipient_emails.each { |email| assert_equal %w[d60 d7], logged_thresholds(certificate, email) }
  end

  test "a corrected expiry date gets its alerts again as the new date approaches" do
    deactivate_fixture_crew!
    travel_to Time.zone.local(2027, 3, 1, 6, 0)
    certificate = create_certificate(create_crew_member, expires_on: Date.current + 5) # typo: should be next year
    Notifications::ExpiryScan.call
    digest_recipient_emails.each { |email| assert_equal %w[d7], logged_thresholds(certificate, email) }

    certificate.update!(expires_on: Date.current + 370)
    travel 300.days # 70 days left
    ActionMailer::Base.deliveries.clear

    assert_emails(digest_recipient_emails.size) { Notifications::ExpiryScan.call }
    digest_recipient_emails.each { |email| assert_equal %w[d90], logged_thresholds(certificate, email) }
  end

  test "a first run on long-expired certificates sends expired once, not the older thresholds" do
    deactivate_fixture_crew!
    certificate = create_certificate(create_crew_member, expires_on: Date.current - 200)

    Notifications::ExpiryScan.call
    Notifications::ExpiryScan.call

    digest_recipient_emails.each { |email| assert_equal %w[expired], logged_thresholds(certificate, email) }
  end

  test "with the fixtures: a digest per recipient with new items only, plus the opted-in crew notice" do
    result = nil
    assert_emails(3) { result = Notifications::ExpiryScan.call }

    assert_equal 2, result.digests_sent
    assert_equal 1, result.crew_notices_sent
    assert_equal 9, result.items_sent # 4 per digest (juan_flagger already had d30) + 1 crew notice
    assert_equal 0, result.deferred
    assert_empty result.failures

    [ users(:admin), users(:manager) ].each do |user|
      mail = ActionMailer::Base.deliveries.find { |each| each.to == [ user.email_address ] }
      assert_equal "CertTrack: 4 certificates need attention", mail.subject
      assert_equal({ "li_first_aid" => "expired", "maria_first_aid" => "expired", "dave_cdl_a" => "d30", "juan_first_aid" => "d60" },
        logged_since_fixtures(user.email_address))
    end
    assert_equal({ "juan_flagger" => "d30" }, logged_since_fixtures(crew_members(:juan_ortiz).email))
    assert_not ActionMailer::Base.deliveries.any? { |mail| mail.to.include?(users(:viewer).email_address) }
  end

  test "superseded, inactive-member and never-expiring certificates are ignored" do
    Notifications::ExpiryScan.call

    %i[juan_flagger_old juan_first_aid_old sam_flagger juan_osha30 dave_osha30 juan_climber li_flagger].each do |name|
      assert_not ExpiryNotification.exists?(certificate: certificates(name)), name
    end
  end

  test "items in a digest list the active projects that need them" do
    Notifications::ExpiryScan.call

    mail = ActionMailer::Base.deliveries.find { |each| each.to == [ users(:admin).email_address ] }
    assert_includes mail.text_part.decoded, "needed on 2417"
  end

  # --- Crew opt-in -------------------------------------------------------------------

  test "crew notices need the opt-in and an email address" do
    deactivate_fixture_crew!
    opted_in = create_crew_member(first_name: "Opted", email: CREW_EMAIL, expiry_emails_opt_in: true)
    no_email = create_crew_member(first_name: "Noemail", expiry_emails_opt_in: true)
    not_opted = create_crew_member(first_name: "Notopted", email: "not.opted@example.com")
    [ opted_in, no_email, not_opted ].each { |member| create_certificate(member, expires_on: Date.current + 20) }

    Notifications::ExpiryScan.call

    crew_mails = ActionMailer::Base.deliveries.reject { |mail| (mail.to & digest_recipient_emails).any? }
    assert_equal [ [ CREW_EMAIL ] ], crew_mails.map(&:to)
    members = [ opted_in, no_email, not_opted ]
    assert_equal 3, ExpiryNotification.where(recipient_email: digest_recipient_emails.first,
      certificate: Certificate.where(crew_member: members)).count, "managers still hear about all three"
  end

  test "crew members are not emailed at d90, d60 or on expiry" do
    deactivate_fixture_crew!
    member = create_crew_member(email: CREW_EMAIL, expiry_emails_opt_in: true)
    [ 80, 45, -3 ].each_with_index do |days, index|
      create_certificate(member, expires_on: Date.current + days, type: CertificateType.create!(name: "Type #{index}", code: "TYPE#{index}"))
    end

    Notifications::ExpiryScan.call

    assert_not ExpiryNotification.exists?(recipient_email: CREW_EMAIL)
    assert ActionMailer::Base.deliveries.none? { |mail| mail.to.include?(CREW_EMAIL) }
  end

  test "a crew notice is its own email about one certificate" do
    deactivate_fixture_crew!
    member = create_crew_member(email: CREW_EMAIL, expiry_emails_opt_in: true)
    create_certificate(member, expires_on: Date.current + 5)
    create_certificate(member, expires_on: Date.current + 25, type: certificate_types(:first_aid))

    Notifications::ExpiryScan.call

    crew_mails = ActionMailer::Base.deliveries.select { |mail| mail.to == [ CREW_EMAIL ] }
    assert_equal 2, crew_mails.size
    assert_equal [ "Your First Aid/CPR/AED certificate", "Your Flagger certificate" ].sort,
      crew_mails.map { |mail| mail.subject[/\AYour .+? certificate/] }.sort
  end

  # --- daily email cap --------------------------------------------------------------

  test "past the daily cap the rest are deferred without log rows and go out the next day" do
    deactivate_fixture_crew!
    travel_to Time.zone.local(2027, 2, 1, 6, 0)
    member = create_crew_member(email: CREW_EMAIL, expiry_emails_opt_in: true)
    certificate = create_certificate(member, expires_on: Date.current + 20)
    limit = Notifications::SendBudget.daily_limit
    Notifications::SendBudget.record!(limit - 1)

    result = nil
    assert_emails(1) { result = Notifications::ExpiryScan.call }

    assert_equal 2, result.deferred
    assert_equal limit, Notifications::SendBudget.sent_today
    assert Notifications::SendBudget.deferred_on?(Date.current)
    assert_equal 2, EmailSendDay.deferred_on(Date.current)
    first_email = ActionMailer::Base.deliveries.last.to.first
    assert_includes digest_recipient_emails, first_email, "digests go before crew notices"
    assert_equal [ first_email ], ExpiryNotification.where(certificate: certificate).pluck(:recipient_email)

    travel 1.day
    ActionMailer::Base.deliveries.clear
    assert_emails(2) { result = Notifications::ExpiryScan.call }

    assert_equal 0, result.deferred
    assert_equal (digest_recipient_emails + [ CREW_EMAIL ]).sort, ExpiryNotification.where(certificate: certificate).pluck(:recipient_email).sort
    assert_not_includes ActionMailer::Base.deliveries.flat_map(&:to), first_email
  end

  test "the cap counts emails, not items" do
    deactivate_fixture_crew!
    member = create_crew_member
    3.times do |index|
      create_certificate(member, expires_on: Date.current + 10 + index, type: CertificateType.create!(name: "Type #{index}", code: "TYPE#{index}"))
    end

    Notifications::ExpiryScan.call

    assert_equal digest_recipient_emails.size, Notifications::SendBudget.sent_today
  end

  # --- Concurrency and failures --------------------------------------------------------

  test "a run that loses the race to claim the log rows sends nothing and returns its reservation" do
    Notifications::ExpiryScan.call
    sent = Notifications::SendBudget.sent_today
    ActionMailer::Base.deliveries.clear

    racer = Notifications::ExpiryScan.new
    racer.define_singleton_method(:sent_log) { |_items| {} } # read the log before the winner wrote it
    result = nil
    assert_no_emails { result = racer.call }

    assert_equal 0, result.items_sent
    assert_equal sent, Notifications::SendBudget.sent_today
  end

  test "only the items a run claimed go in its digest" do
    deactivate_fixture_crew!
    member = create_crew_member
    taken = create_certificate(member, expires_on: Date.current + 10)
    create_certificate(member, expires_on: Date.current + 12, type: certificate_types(:first_aid))
    admin_email = users(:admin).email_address
    in_flight = ExpiryNotification.create!(certificate: taken, threshold: :d30, recipient_email: admin_email)

    racer = Notifications::ExpiryScan.new
    racer.define_singleton_method(:sent_log) { |_items| {} }
    racer.call

    admin_mail = ActionMailer::Base.deliveries.find { |mail| mail.to == [ admin_email ] }
    assert_equal "CertTrack: 1 certificate needs attention", admin_mail.subject
    assert_nil in_flight.reload.sent_at, "the other run's claim is left alone"
  end

  test "a failed delivery drops its claims so the next run retries it" do
    deactivate_fixture_crew!
    certificate = create_certificate(create_crew_member, expires_on: Date.current + 10)
    admin_email = users(:admin).email_address

    result = with_failing_expiry_mailer(fail_for: ->(params) { params[:user] == users(:admin) }) do
      Notifications::ExpiryScan.call
    end

    assert_equal 1, result.failures.size
    assert_kind_of Errno::ECONNREFUSED, result.failures.first
    assert_equal [ users(:manager).email_address ], ActionMailer::Base.deliveries.flat_map(&:to)
    assert_empty logged_thresholds(certificate, admin_email)

    ActionMailer::Base.deliveries.clear
    assert_emails(1) { Notifications::ExpiryScan.call }
    assert_equal [ admin_email ], ActionMailer::Base.deliveries.last.to
    assert_equal %w[d30], logged_thresholds(certificate, admin_email)
  end

  test "one failure doesn't stop the other recipients" do
    result = with_failing_expiry_mailer { Notifications::ExpiryScan.call }

    assert_equal 3, result.failures.size
    assert_equal 0, result.items_sent
    assert_equal 2, ExpiryNotification.count, "only the fixture rows remain"
    assert_equal 0, Notifications::SendBudget.sent_today, "failed sends hand their reservations back"
  end

  private
    # {certificate fixture label => threshold} logged to email by this test (the fixture rows excluded).
    def logged_since_fixtures(email)
      fixture_rows = [ expiry_notifications(:juan_flagger_d30_admin).id, expiry_notifications(:juan_flagger_d30_manager).id ]
      labels = ActiveRecord::FixtureSet.all_loaded_fixtures.fetch("certificates").fixtures.keys
        .index_by { |label| ActiveRecord::FixtureSet.identify(label) }

      ExpiryNotification.where(recipient_email: email).where.not(id: fixture_rows)
        .to_h { |notification| [ labels.fetch(notification.certificate_id), notification.threshold ] }
    end
end
