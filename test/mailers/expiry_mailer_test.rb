require "test_helper"
require_relative "previews/expiry_mailer_preview"

class ExpiryMailerTest < ActionMailer::TestCase
  setup do
    @tower = projects(:tower_2417)
    @tower_2420 = Project.create!(name: "Tower 2420 Build", code: "2420", status: :active)
  end

  # --- daily_digest ---

  test "daily digest goes to the user with a count in the subject" do
    mail = ExpiryMailer.with(user: users(:manager), items: [ juan_flagger_item, maria_first_aid_item ]).daily_digest

    assert_equal [ "manager@example.com" ], mail.to
    assert_equal "CertTrack: 2 certificates need attention", mail.subject
    assert mail.html_part.present? && mail.text_part.present?

    single = ExpiryMailer.with(user: users(:manager), items: [ juan_flagger_item ]).daily_digest
    assert_equal "CertTrack: 1 certificate needs attention", single.subject
  end

  test "daily digest groups by project, then person, with items off projects last" do
    items = [ juan_flagger_item, maria_first_aid_item, dave_cdl_item, sam_flagger_item ]
    text = ExpiryMailer.with(user: users(:admin), items: items).daily_digest.text_part.body.to_s

    sections = [ "2417 · Tower 2417 Upgrade", "2420 · Tower 2420 Build", "Not on an active project" ]
    assert_in_order text, sections

    tower = text[text.index(sections[0])...text.index(sections[1])]
    assert_in_order tower, [ "Mari Garcia", "Dave Miller", "Juan Ortiz" ] # by last name
    assert_includes tower, "Flagger, expires Dec 1, 2026 (in 29 days), needed on 2417 and 2420 [30 days]"
    assert_includes tower, "First Aid/CPR/AED, expired #{(Date.current - 5).strftime("%b %-d, %Y")}, needed on 2417 [Expired 5 days ago]"
    assert_includes tower, "CDL Class A, expires Nov 27, 2026 (in 25 days), needed on 2417 [30 days]"

    tower_2420 = text[text.index(sections[1])...text.index(sections[2])]
    assert_includes tower_2420, "Juan Ortiz"
    assert_not_includes tower_2420, "Garcia"

    off_project = text[text.index(sections[2])..]
    assert_includes off_project, "Sam Price"
    assert_includes off_project, "Flagger, expires Nov 9, 2026 (in 7 days) [7 days]"
  end

  test "daily digest links to member and compliance pages with the configured host" do
    mail = ExpiryMailer.with(user: users(:admin), items: [ juan_flagger_item ]).daily_digest
    juan = crew_members(:juan_ortiz)

    html = mail.html_part.body.to_s
    assert_includes html, %(href="http://example.com/crew_members/#{juan.id}")
    assert_includes html, %(href="http://example.com/projects/#{@tower.id}/compliance")
    assert_includes html, %(href="http://example.com/users")

    text = mail.text_part.body.to_s
    assert_includes text, "Juan Ortiz: http://example.com/crew_members/#{juan.id}"
    assert_includes text, "http://example.com/projects/#{@tower_2420.id}/compliance"
    assert_includes text, "You receive this because daily digests are on for your account (admin@example.com)."
    assert_includes text, "Users page: http://example.com/users"
  end

  test "daily digest labels every threshold" do
    labels = {
      "d90" => [ 85, "[90 days]" ], "d60" => [ 45, "[60 days]" ], "d30" => [ 20, "[30 days]" ],
      "d7" => [ 0, "(today), needed on 2417 [7 days]" ], "expired" => [ -1, "[Expired 1 day ago]" ]
    }
    items = labels.map do |threshold, (days_left, _)|
      item(:juan_flagger, threshold: threshold, days_left: days_left, projects: [ @tower ])
    end

    text = ExpiryMailer.with(user: users(:admin), items: items).daily_digest.text_part.body.to_s
    labels.each_value { |_, label| assert_includes text, label }
  end

  test "a test digest is marked as a test, and sample data renders without links" do
    mail = ExpiryMailer.with(user: users(:admin), items: ExpiryMailer.sample_items, test: true, sample: true).daily_digest

    assert_equal "[Test] CertTrack: 3 certificates need attention", mail.subject
    assert_includes mail.text_part.body.to_s, "TEST DIGEST. Nothing is within 90 days of expiry"
    assert_includes mail.html_part.body.to_s, "Test digest."
    assert_not_includes mail.html_part.body.to_s, "/crew_members/"
    assert_includes mail.text_part.body.to_s, "Alex Example"
  end

  # --- weekly_digest ---

  test "weekly digest lists expiring certificates and gaps by project" do
    gaps = [
      gap(:maria_garcia, :flagger, "missing"),
      gap(:li_chen, :first_aid, "expired", certificates(:li_first_aid)),
      gap(:dave_miller, :first_aid, "missing", project: @tower_2420)
    ]
    mail = ExpiryMailer.with(user: users(:manager), expiring: [ juan_flagger_item, dave_cdl_item ], gaps: gaps).weekly_digest

    assert_equal [ "manager@example.com" ], mail.to
    assert_equal "CertTrack weekly: 2 expiring soon, 3 gaps on active projects", mail.subject

    text = mail.text_part.body.to_s
    assert_in_order text, [ "EXPIRED OR EXPIRING WITHIN 30 DAYS", "Dave Miller, CDL Class A, expires Nov 27, 2026", "Juan Ortiz, Flagger, expires Dec 1, 2026",
      "GAPS ON ACTIVE PROJECTS" ]
    assert_in_order text, [ "2417 · Tower 2417 Upgrade", "Li Chen, First Aid/CPR/AED: Expired", "Mari Garcia, Flagger: Missing",
      "2420 · Tower 2420 Build", "Dave Miller, First Aid/CPR/AED: Missing" ]
    assert_includes text, "http://example.com/projects/#{@tower.id}/compliance"
    assert_includes text, "digest emails are on for your account (manager@example.com)"

    html = mail.html_part.body.to_s
    assert_includes html, %(href="http://example.com/crew_members/#{crew_members(:maria_garcia).id}")
    assert_includes html, "Expired #{certificates(:li_first_aid).expires_on.strftime("%b %-d, %Y")}"
  end

  test "weekly digest is still sent when there is nothing to report" do
    mail = ExpiryMailer.with(user: users(:admin), expiring: [], gaps: []).weekly_digest

    assert_equal "CertTrack weekly: all clear", mail.subject
    assert_includes mail.text_part.body.to_s, "All clear. Nothing has expired or expires in the next 30 days"
    assert_includes mail.html_part.body.to_s, "All clear."
  end

  test "weekly digest counts already-expired certificates separately" do
    mail = ExpiryMailer.with(user: users(:admin), expiring: [ maria_first_aid_item, juan_flagger_item ], gaps: []).weekly_digest

    assert_equal "CertTrack weekly: 1 expiring soon, 1 expired", mail.subject
    text = mail.text_part.body.to_s
    assert_includes text, "1 certificate expiring within 30 days, 1 already expired, and 0 gaps"
    assert_in_order text, [ "Mari Garcia, First Aid/CPR/AED, expired", "Juan Ortiz, Flagger", "No gaps:" ]
  end

  test "weekly digest shows an empty section when only one side has entries" do
    text = ExpiryMailer.with(user: users(:admin), expiring: [], gaps: [ gap(:maria_garcia, :flagger, "missing") ])
      .weekly_digest.text_part.body.to_s

    assert_includes text, "Nothing has expired or expires in the next 30 days."
    assert_includes text, "Mari Garcia, Flagger: Missing"
  end

  test "weekly digest accepts gaps from the compliance report" do
    gaps = Compliance::ProjectReport.new(@tower).gaps
    mail = ExpiryMailer.with(user: users(:admin), expiring: [], gaps: gaps).weekly_digest

    assert_operator gaps.size, :>, 0
    assert_includes mail.text_part.body.to_s, "Mari Garcia, Flagger: Missing"
  end

  test "weekly digest labels a gap a person confirmed fake" do
    certificates(:li_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:not_found],
      authenticity_method: Authenticity::PERSON_METHOD)
    gaps = Compliance::ProjectReport.new(@tower).gaps
    mail = ExpiryMailer.with(user: users(:admin), expiring: [], gaps: gaps).weekly_digest

    assert_includes mail.text_part.body.to_s, "Li Chen, Flagger: Confirmed fake"
    assert_includes mail.text_part.body.to_s, "6 gaps (missing, expired or confirmed fake)"
    assert_includes mail.html_part.body.to_s, "Confirmed fake"
    assert_includes mail.html_part.body.to_s, "(missing, expired or confirmed fake)"
    assert_equal "CertTrack weekly: 6 gaps on active projects", mail.subject
  end

  test "weekly digest doesn't count a certificate only flagged for review as a gap" do
    certificates(:li_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:not_found],
      authenticity_method: "automatic:aha_ecards")
    gaps = Compliance::ProjectReport.new(@tower).gaps
    mail = ExpiryMailer.with(user: users(:admin), expiring: [], gaps: gaps).weekly_digest

    assert_not_includes mail.text_part.body.to_s, "Li Chen, Flagger"
    assert_includes mail.text_part.body.to_s, "5 gaps (missing, expired or confirmed fake)"
    assert_equal "CertTrack weekly: 5 gaps on active projects", mail.subject
  end

  test "a certificate flagged for review or confirmed fake still gets its expiry reminders" do
    certificate = certificates(:juan_flagger)
    [ "automatic:aha_ecards", Authenticity::PERSON_METHOD ].each do |method|
      certificate.update_columns(authenticity_status: Certificate.authenticity_statuses[:mismatch], authenticity_method: method)

      mail = ExpiryMailer.with(user: users(:manager), items: [ juan_flagger_item ]).daily_digest
      assert_includes mail.text_part.body.to_s, "Flagger, expires", method

      notice = ExpiryMailer.with(crew_member: certificate.crew_member, certificate: certificate.reload, threshold: "d30").crew_notice
      assert_equal [ "juan.ortiz@example.com" ], notice.to
      assert_match(/\AYour Flagger certificate expires /, notice.subject)
    end
  end

  # --- crew_notice ---

  test "crew notice goes to the crew member about their own certificate only" do
    certificate = certificates(:juan_flagger)
    mail = with_env("OFFICE_EMAIL" => "office@abaventures.net") do
      ExpiryMailer.with(crew_member: crew_members(:juan_ortiz), certificate: certificate, threshold: "d30").crew_notice.message
    end
    date = certificate.expires_on.strftime("%b %-d, %Y")

    assert_equal [ "juan.ortiz@example.com" ], mail.to
    assert_equal "Your Flagger certificate expires #{date}", mail.subject
    assert_equal [ "office@abaventures.net" ], mail.reply_to

    [ mail.text_part.body.to_s, mail.html_part.body.to_s ].each do |body|
      assert_includes body, "Hi Juan,"
      assert_includes body, "expires #{date} (in #{certificate.days_until_expiry} days)"
      assert_includes body, "send a copy of the"
      assert_includes body, "reply to this email"

      CrewMember.where.not(id: crew_members(:juan_ortiz).id).find_each do |other|
        assert_not_includes body, other.last_name, "crew notice leaked #{other.full_name}"
      end
      assert_not_includes body, "FL-20002" # no certificate numbers by email
      assert_not_includes body, "http://example.com" # no app links: crew members have no accounts
      User.find_each { |user| assert_not_includes body, user.email_address }
      assert_not_includes body, "Tower 2417"
    end
  end

  test "crew notice replies to the office address when OFFICE_EMAIL is set" do
    with_env("OFFICE_EMAIL" => "office@abaventures.net") do
      mail = ExpiryMailer.with(crew_member: crew_members(:juan_ortiz), certificate: certificates(:juan_flagger), threshold: "d7").crew_notice

      assert_equal [ "office@abaventures.net" ], mail.reply_to
      assert_includes mail.text_part.body.to_s, "or write to office@abaventures.net"
    end
  end

  test "without OFFICE_EMAIL the crew notice has no Reply-To and doesn't ask for a reply" do
    mail = with_env("OFFICE_EMAIL" => nil) do
      ExpiryMailer.with(crew_member: crew_members(:juan_ortiz), certificate: certificates(:juan_flagger), threshold: "d7").crew_notice.message
    end

    assert_nil mail.reply_to
    [ mail.text_part.body.to_s, mail.html_part.body.to_s ].each do |body|
      assert_includes body, "to the office."
      assert_includes body, "To stop them, ask the office."
      assert_no_match(/reply/i, body)
    end
  end

  test "crew notice for an expired certificate says so" do
    certificate = certificates(:maria_first_aid)
    mail = ExpiryMailer.with(crew_member: crew_members(:maria_garcia), certificate: certificate, threshold: "expired").crew_notice

    assert_equal "Your First Aid/CPR/AED certificate expired #{certificate.expires_on.strftime("%b %-d, %Y")}", mail.subject
    assert_includes mail.text_part.body.to_s, "Hi Mari,"
    assert_includes mail.text_part.body.to_s, "renew it as soon as you can"
  end

  test "crew notice sends nothing when the crew member has no email" do
    assert_no_emails do
      ExpiryMailer.with(crew_member: crew_members(:dave_miller), certificate: certificates(:dave_cdl_a), threshold: "d30").crew_notice.deliver_now
    end
  end

  test "crew notice refuses another person's certificate" do
    assert_raises(ArgumentError) do
      ExpiryMailer.with(crew_member: crew_members(:juan_ortiz), certificate: certificates(:maria_first_aid), threshold: "d30").crew_notice.message
    end
  end

  # --- previews ---

  test "every preview renders with data" do
    assert_previews_render
  end

  test "every preview renders on an empty database" do
    ActiveRecord::Base.connection.execute("TRUNCATE users, crew_members, certificate_types, projects, crew_roles CASCADE")
    assert_equal 0, User.count

    assert_previews_render
  end

  private
    def item(fixture, threshold:, days_left:, projects:, expires_on: Date.current + days_left)
      certificate = certificates(fixture)
      Notifications::DigestItem.new(certificate: certificate, crew_member: certificate.crew_member,
        certificate_type: certificate.certificate_type, threshold: threshold, expires_on: expires_on,
        days_left: days_left, projects: projects)
    end

    def juan_flagger_item
      item(:juan_flagger, threshold: "d30", expires_on: Date.new(2026, 12, 1), days_left: 29, projects: [ @tower, @tower_2420 ])
    end

    def maria_first_aid_item
      item(:maria_first_aid, threshold: "expired", days_left: -5, projects: [ @tower ])
    end

    def dave_cdl_item
      item(:dave_cdl_a, threshold: "d30", expires_on: Date.new(2026, 11, 27), days_left: 25, projects: [ @tower ])
    end

    def sam_flagger_item
      item(:sam_flagger, threshold: "d7", expires_on: Date.new(2026, 11, 9), days_left: 7, projects: [])
    end

    def gap(member, type, status, certificate = nil, project: @tower)
      Compliance::ProjectReport::Gap.new(project: project, crew_member: crew_members(member),
        certificate_type: certificate_types(type), status: status, certificate: certificate)
    end

    def assert_in_order(text, fragments)
      positions = fragments.map do |fragment|
        text.index(fragment) || flunk("expected to find #{fragment.inspect} in:\n#{text}")
      end
      assert_equal positions.sort, positions, "expected #{fragments.inspect} in that order"
    end

    def assert_previews_render
      preview = ExpiryMailerPreview.new
      %i[daily_digest test_digest_with_sample_data weekly_digest weekly_digest_all_clear crew_notice].each do |email|
        message = preview.public_send(email).message
        assert message.subject.present?, "#{email} has no subject"
        assert message.to.present?, "#{email} has no recipient"
        assert message.html_part.body.to_s.present?, "#{email} has no HTML part"
        assert message.text_part.body.to_s.present?, "#{email} has no text part"
      end
    end

    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
end
