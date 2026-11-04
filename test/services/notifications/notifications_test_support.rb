# Helpers shared by the expiry notification tests.
module NotificationsTestSupport
  # Takes the fixture crew out of the scan so a test controls exactly what is expiring.
  def deactivate_fixture_crew!
    CrewMember.update_all(active: false)
  end

  def create_crew_member(first_name: "Pat", last_name: "Tester", **attributes)
    CrewMember.create!(first_name: first_name, last_name: last_name, crew_role: crew_roles(:laborer), **attributes)
  end

  # A current certificate with a manual expiry date.
  def create_certificate(crew_member, expires_on:, type: certificate_types(:flagger), **attributes)
    completed_on = [ Date.current, expires_on ].min - 365
    Certificate.create!(crew_member: crew_member, certificate_type: type,
      completed_on: completed_on, expires_on: expires_on, **attributes)
  end

  def logged_thresholds(certificate, email)
    ExpiryNotification.where(certificate: certificate, recipient_email: email).order(:threshold).pluck(:threshold)
  end

  def digest_recipient_emails
    User.digest_recipients.order(:id).pluck(:email_address)
  end

  # Number of SQL queries the block runs (schema and transaction statements excluded). The query
  # cache is off inside the block so the count does not depend on row order or earlier queries.
  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ActiveRecord::Base.uncached(&block) }
    count
  end

  # Replaces ExpiryMailer.with for the block. fail_for decides, per params hash, whether the
  # delivery raises; everything else goes through the real mailer.
  def with_failing_expiry_mailer(fail_for: ->(_params) { true })
    original = ExpiryMailer.method(:with)
    ExpiryMailer.define_singleton_method(:with) do |**params|
      raise Errno::ECONNREFUSED, "smtp.gmail.com" if fail_for.call(params)

      original.call(**params)
    end
    yield
  ensure
    ExpiryMailer.singleton_class.remove_method(:with)
  end
end
