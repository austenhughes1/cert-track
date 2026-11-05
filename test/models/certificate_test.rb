require "test_helper"

class CertificateTest < ActiveSupport::TestCase
  setup do
    @member = CrewMember.create!(first_name: "Test", last_name: "Person")
    @flagger = certificate_types(:flagger) # 36 months
    @osha30 = certificate_types(:osha30)   # never expires
  end

  def create_cert(type: @flagger, member: @member, **attrs)
    Certificate.create!(crew_member: member, certificate_type: type, **attrs)
  end

  def current_for(member, type)
    Certificate.current.where(crew_member: member, certificate_type: type).sole
  end

  # --- Expiration date ---

  test "computes expires_on from validity when blank" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14))
    assert_equal Date.new(2028, 3, 14), cert.expires_on
    assert cert.expiry_computed?
  end

  test "computes month-end dates" do
    cert = create_cert(type: certificate_types(:first_aid), completed_on: Date.new(2024, 2, 29))
    assert_equal Date.new(2026, 2, 28), cert.expires_on
  end

  test "never-expiring type leaves expires_on nil with source none" do
    cert = create_cert(type: @osha30, completed_on: Date.new(2025, 3, 14))
    assert_nil cert.expires_on
    assert cert.expiry_none?
    assert cert.never_expires?
  end

  test "an explicit date is kept and marked manual" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14), expires_on: Date.new(2026, 1, 1))
    assert_equal Date.new(2026, 1, 1), cert.expires_on
    assert cert.expiry_manual?
  end

  test "callers can mark an explicit date as printed" do
    cert = create_cert(type: @osha30, completed_on: Date.new(2025, 3, 14), expires_on: Date.new(2027, 3, 14), expires_on_source: :printed)
    assert cert.expiry_printed?
    assert_equal Date.new(2027, 3, 14), cert.expires_on
  end

  test "printed source without a date falls back to the rule" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14), expires_on_source: :printed)
    assert cert.expiry_computed?
  end

  test "completed_on is required and cannot be in the future" do
    cert = Certificate.new(crew_member: @member, certificate_type: @flagger)
    assert_not cert.valid?
    assert_includes cert.errors[:completed_on], "can't be blank"

    cert.completed_on = Date.current + 1
    assert_not cert.valid?
    assert_includes cert.errors[:completed_on], "can't be in the future"

    cert.completed_on = Date.current
    assert cert.valid?
  end

  test "future check uses Denver's date" do
    travel_to Time.utc(2026, 11, 3, 3, 0) do # 8 p.m. Nov 2 in Denver
      cert = Certificate.new(crew_member: @member, certificate_type: @flagger, completed_on: Date.new(2026, 11, 3))
      assert_not cert.valid?
    end
  end

  test "expires_on cannot be before completed_on" do
    cert = Certificate.new(crew_member: @member, certificate_type: @flagger,
      completed_on: Date.new(2025, 3, 14), expires_on: Date.new(2025, 3, 13))
    assert_not cert.valid?
    assert_includes cert.errors[:expires_on], "can't be before the completion date"
    cert.expires_on = Date.new(2025, 3, 14)
    assert cert.valid?
  end

  test "editing completed_on recomputes a computed date" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14))
    cert.update!(completed_on: Date.new(2025, 6, 1), expires_on: cert.expires_on) # form resubmits the old date
    assert_equal Date.new(2028, 6, 1), cert.expires_on
    assert cert.expiry_computed?
  end

  test "changing type recomputes a computed date" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14))
    cert.update!(certificate_type: certificate_types(:first_aid))
    assert_equal Date.new(2027, 3, 14), cert.expires_on

    cert.update!(certificate_type: @osha30)
    assert_nil cert.expires_on
    assert cert.expiry_none?
  end

  test "editing completed_on keeps a manual or printed date" do
    manual = create_cert(completed_on: Date.new(2025, 3, 14), expires_on: Date.new(2026, 1, 1))
    manual.update!(completed_on: Date.new(2025, 4, 1))
    assert_equal Date.new(2026, 1, 1), manual.expires_on
    assert manual.expiry_manual?

    printed = create_cert(type: certificate_types(:first_aid), completed_on: Date.new(2025, 3, 14),
      expires_on: Date.new(2027, 1, 1), expires_on_source: :printed)
    printed.update!(completed_on: Date.new(2025, 4, 1))
    assert_equal Date.new(2027, 1, 1), printed.expires_on
    assert printed.expiry_printed?
  end

  test "typing over a computed date makes it manual" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14))
    cert.update!(completed_on: Date.new(2025, 4, 1), expires_on: Date.new(2026, 12, 31))
    assert_equal Date.new(2026, 12, 31), cert.expires_on
    assert cert.expiry_manual?
  end

  test "clearing a manual date reapplies the rule" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14), expires_on: Date.new(2026, 1, 1))
    cert.update!(expires_on: nil)
    assert_equal Date.new(2028, 3, 14), cert.expires_on
    assert cert.expiry_computed?
  end

  # --- Type validity changes ---

  test "setting validity on a type that had none dates its never-expiring certificates" do
    type = CertificateType.create!(name: "Fall Protection", code: "FALLPROT") # seeded without validity
    cert = create_cert(type: type, completed_on: Date.current - 3.years)
    assert cert.expiry_none?
    assert_equal "valid", cert.compliance_status

    type.update!(validity_months: 24)

    cert.reload
    assert_equal (Date.current - 3.years).advance(months: 24), cert.expires_on
    assert cert.expiry_computed?
    assert_equal "expired", cert.compliance_status
    assert_includes Certificate.current.expired, cert
  end

  test "changing validity re-dates computed rows, history included, and keeps printed and manual dates" do
    computed = create_cert(completed_on: Date.new(2025, 3, 14))
    history = create_cert(completed_on: Date.new(2022, 3, 14))
    manual = create_cert(member: CrewMember.create!(first_name: "Other", last_name: "Person"),
      completed_on: Date.new(2025, 3, 14), expires_on: Date.new(2026, 1, 1))
    printed = create_cert(member: CrewMember.create!(first_name: "Third", last_name: "Person"),
      completed_on: Date.new(2025, 3, 14), expires_on: Date.new(2027, 1, 1), expires_on_source: :printed)
    assert history.reload.superseded?

    @flagger.update!(validity_months: 12)

    assert_equal @flagger.certificates.where(expires_on_source: %i[computed none]).count, @flagger.rederived_certificate_count
    assert_operator @flagger.rederived_certificate_count, :>=, 2
    assert_equal [ Date.new(2026, 3, 14), "computed" ], [ computed.reload.expires_on, computed.expires_on_source ]
    assert_equal Date.new(2023, 3, 14), history.reload.expires_on
    assert_equal [ Date.new(2026, 1, 1), "manual" ], [ manual.reload.expires_on, manual.expires_on_source ]
    assert_equal [ Date.new(2027, 1, 1), "printed" ], [ printed.reload.expires_on, printed.expires_on_source ]
  end

  test "clearing validity makes computed rows never expire" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14))

    @flagger.update!(validity_months: nil)

    assert_nil cert.reload.expires_on
    assert cert.expiry_none?
  end

  test "other type edits leave certificates alone" do
    cert = create_cert(completed_on: Date.new(2025, 3, 14))

    assert_no_changes -> { cert.reload.updated_at } do
      @flagger.update!(name: "Flagger (ATSSA)", aliases: [ "Flagger Card" ])
    end
    assert_nil @flagger.rederived_certificate_count
  end

  test "a validity change re-arms the send log for the new date" do
    cert = certificates(:juan_flagger) # computed, ~10 days out, d30 logged for both digest users
    assert_equal 2, cert.expiry_notifications.count

    @flagger.update!(validity_months: 60) # now about two years out

    assert cert.reload.expires_on > Date.current + 90
    assert_empty cert.expiry_notifications
  end

  test "rederive_expiry! ignores printed and manual dates and reports whether it changed anything" do
    assert_not certificates(:li_flagger).rederive_expiry!
    assert_not certificates(:dave_cdl_a).rederive_expiry!
    assert_not certificates(:juan_flagger).rederive_expiry! # already matches the validity
  end

  # --- Current / supersede ---

  test "a newer certificate supersedes the current one" do
    old = create_cert(completed_on: Date.new(2022, 1, 10))
    newer = create_cert(completed_on: Date.new(2025, 1, 10))

    assert newer.current?
    assert old.reload.superseded?
    assert_in_delta Time.current, old.superseded_at, 5.seconds
    assert_equal newer, current_for(@member, @flagger)
  end

  test "entering an older historical certificate leaves the newer one current" do
    newer = create_cert(completed_on: Date.new(2025, 1, 10))
    older = create_cert(completed_on: Date.new(2022, 1, 10))

    assert older.superseded?
    assert newer.reload.current?
    assert_equal newer, current_for(@member, @flagger)
  end

  test "a same-day tie goes to the higher id" do
    first = create_cert(completed_on: Date.new(2025, 1, 10))
    second = create_cert(completed_on: Date.new(2025, 1, 10))
    assert second.current?
    assert first.reload.superseded?
  end

  test "certificates of other types and people are independent" do
    flagger = create_cert(completed_on: Date.new(2025, 1, 10))
    create_cert(type: @osha30, completed_on: Date.new(2025, 2, 10))
    create_cert(member: crew_members(:li_chen), completed_on: Date.new(2026, 1, 10))
    assert flagger.reload.current?
  end

  test "keeps existing superseded_at for history rows" do
    oldest = create_cert(completed_on: Date.new(2019, 1, 10))
    create_cert(completed_on: Date.new(2022, 1, 10))
    stamped = oldest.reload.superseded_at
    travel 1.day do
      create_cert(completed_on: Date.new(2025, 1, 10))
    end
    assert_equal stamped, oldest.reload.superseded_at
  end

  test "editing a history row to be the newest promotes it" do
    old = create_cert(completed_on: Date.new(2022, 1, 10))
    current = create_cert(completed_on: Date.new(2024, 1, 10))
    old.reload.update!(completed_on: Date.new(2025, 1, 10))

    assert old.current?
    assert current.reload.superseded?
  end

  test "editing the current row to be older promotes the rival" do
    old = create_cert(completed_on: Date.new(2022, 1, 10))
    current = create_cert(completed_on: Date.new(2024, 1, 10))
    current.update!(completed_on: Date.new(2021, 1, 10))

    assert current.reload.superseded?
    assert old.reload.current?
  end

  test "moving a certificate to another person re-promotes in both groups" do
    other = CrewMember.create!(first_name: "Other", last_name: "Person")
    old = create_cert(completed_on: Date.new(2022, 1, 10))
    moved = create_cert(completed_on: Date.new(2024, 1, 10))
    others_cert = create_cert(member: other, completed_on: Date.new(2023, 1, 10))

    moved.update!(crew_member: other)

    assert old.reload.current?
    assert moved.reload.current?
    assert others_cert.reload.superseded?
  end

  test "destroying the current certificate re-promotes the previous one" do
    oldest = create_cert(completed_on: Date.new(2019, 1, 10))
    previous = create_cert(completed_on: Date.new(2022, 1, 10))
    current = create_cert(completed_on: Date.new(2025, 1, 10))

    current.destroy!
    assert previous.reload.current?
    assert oldest.reload.superseded?
  end

  test "destroying a history row leaves the current one alone" do
    old = create_cert(completed_on: Date.new(2022, 1, 10))
    current = create_cert(completed_on: Date.new(2025, 1, 10))
    old.reload.destroy!
    assert current.reload.current?
  end

  test "the database allows only one current certificate per member and type" do
    create_cert(completed_on: Date.new(2025, 1, 10))
    assert_raises(ActiveRecord::RecordNotUnique) do
      Certificate.insert_all!([ { crew_member_id: @member.id, certificate_type_id: @flagger.id, completed_on: Date.new(2024, 1, 1) } ])
    end
  end

  test "a newer certificate a person confirmed fake ranks below the genuine one, which stays current" do
    genuine = create_cert(completed_on: Date.new(2025, 1, 10))
    fake = create_cert(completed_on: Date.new(2026, 6, 1))
    assert fake.current?

    fake.record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    assert fake.superseded?
    assert_equal genuine, current_for(@member, @flagger)
    assert_equal "valid", genuine.reload.compliance_status

    fake.record_authenticity!(status: :verified, method: "person", by: users(:manager))
    assert fake.current?, "no longer fake: the newest is current again"
    assert genuine.reload.superseded?
  end

  test "an automatic not found or mismatch never changes which certificate is current" do
    older = create_cert(completed_on: Date.new(2025, 1, 10))
    newer = create_cert(completed_on: Date.new(2026, 6, 1))

    newer.record_authenticity!(status: :not_found, method: "automatic:aha_ecards")
    older.reload.record_authenticity!(status: :mismatch, method: "rules")
    assert newer.reload.current?
    assert older.reload.superseded?

    newer.update_columns(authenticity_status: "suspicious", authenticity_method: "person")
    Certificate.reconcile_current!(@member.id, @flagger.id)
    assert newer.reload.current?, "a suspicious result is never fake, even marked person"
  end

  test "a genuine replacement completed before a fake one's made-up date becomes current" do
    fake = create_cert(completed_on: Date.new(2026, 6, 1))
    fake.record_authenticity!(status: :mismatch, method: "person", by: users(:manager))
    assert fake.current?, "the only one: current, so its cell reads Confirmed fake"

    replacement = create_cert(completed_on: Date.new(2025, 3, 1))
    assert replacement.current?
    assert fake.reload.superseded?
  end

  test "when every certificate is confirmed fake the latest is current" do
    older = create_cert(completed_on: Date.new(2025, 1, 10))
    newer = create_cert(completed_on: Date.new(2026, 6, 1))
    [ older, newer ].each { it.reload.record_authenticity!(status: :not_found, method: "person", by: users(:manager)) }

    assert newer.reload.current?
    assert older.reload.superseded?
  end

  test "reconcile_current! ranks confirmed fake ones last" do
    genuine = create_cert(completed_on: Date.new(2025, 1, 10))
    fake = create_cert(completed_on: Date.new(2026, 6, 1))
    fake.update_columns(authenticity_status: "not_found", authenticity_method: "person")

    Certificate.reconcile_current!(@member.id, @flagger.id)
    assert genuine.reload.current?
    assert fake.reload.superseded?
  end

  test "reconcile_current! repairs a group" do
    a = create_cert(completed_on: Date.new(2022, 1, 10))
    b = create_cert(completed_on: Date.new(2025, 1, 10))
    Certificate.where(id: [ a.id, b.id ]).update_all(superseded_at: 1.day.ago)

    Certificate.reconcile_current!(@member.id, @flagger.id)
    assert b.reload.current?
    assert a.reload.superseded?
  end

  test "a save from a copy loaded before its group changed still leaves exactly one current, read back into the copy" do
    a = create_cert(completed_on: Date.new(2025, 1, 10))
    stale = Certificate.find(a.id) # current when loaded
    b = create_cert(completed_on: Date.new(2025, 6, 1))
    assert a.reload.superseded?, "b is newer"

    stale.update!(completed_on: Date.new(2026, 1, 10)) # now the newest, but the copy still says current

    assert a.reload.current?
    assert b.reload.superseded?
    assert stale.current?
    assert_not stale.changed?, "the flag read back is not a pending change"

    late = Certificate.find(b.id) # superseded when loaded
    a.update!(completed_on: Date.new(2024, 1, 10))
    assert b.reload.current?
    late.update!(notes: "Checked", completed_on: Date.new(2025, 6, 2))
    assert_equal [ b.id ], Certificate.current.where(crew_member: @member, certificate_type: @flagger).pluck(:id)
    assert late.current?, "read back: the copy said superseded"
  end

  test "destroying a certificate locks its crew member before its row, as Verification::Run does" do
    certificate = create_cert(completed_on: Date.new(2025, 1, 10))
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    Certificate.find(certificate.id).destroy!
    ActiveSupport::Notifications.unsubscribe(subscriber)

    member_lock = statements.index { it.match?(/FROM "crew_members".*FOR UPDATE/m) }
    delete = statements.index { it.match?(/\ADELETE FROM "certificates"/) }
    assert member_lock && delete, statements.join("\n")
    assert_operator member_lock, :<, delete
  end

  test "destroying a certificate keeps the import item and deletes notifications" do
    cert = certificates(:li_flagger)
    item = import_items(:accepted_li_flagger)
    cert.destroy!

    assert_nil item.reload.certificate_id
    assert_empty ExpiryNotification.where(certificate_id: cert.id)
    assert_difference -> { ExpiryNotification.count }, -2 do
      certificates(:juan_flagger).destroy!
    end
    assert certificates(:juan_flagger_old).reload.current?
  end

  # --- Scopes and helpers ---

  test "current and superseded scopes over fixtures" do
    assert_includes Certificate.current, certificates(:juan_flagger)
    assert_not_includes Certificate.current, certificates(:juan_flagger_old)
    assert_equal [ certificates(:juan_first_aid_old), certificates(:juan_flagger_old) ].sort_by(&:id), Certificate.superseded.order(:id).to_a
  end

  test "expiring_within and expired" do
    today = Date.new(2026, 11, 2)
    expiring = create_cert(completed_on: Date.new(2023, 11, 12)) # expires 2026-11-12
    expired = create_cert(type: certificate_types(:first_aid), completed_on: Date.new(2024, 10, 1)) # 2026-10-01
    never = create_cert(type: @osha30, completed_on: Date.new(2024, 10, 1))
    mine = Certificate.where(crew_member: @member)

    assert_equal [ expiring ], mine.expiring_within(30, today: today).to_a
    assert_empty mine.expiring_within(9, today: today)
    assert_equal [ expired ], mine.expired(today: today).to_a
    assert_equal [ never ], mine.never_expiring.to_a
  end

  test "expiring_within defaults to Denver's today" do
    assert_includes Certificate.current.expiring_within(30), certificates(:juan_flagger)
    assert_includes Certificate.expired, certificates(:maria_first_aid)
    assert_not_includes Certificate.expiring_within(30), certificates(:maria_first_aid)
  end

  test "days_until_expiry and compliance_status" do
    cert = Certificate.new(expires_on: Date.new(2026, 11, 12))
    assert_equal 10, cert.days_until_expiry(today: Date.new(2026, 11, 2))
    assert_equal(-1, cert.days_until_expiry(today: Date.new(2026, 11, 13)))
    assert_nil Certificate.new.days_until_expiry
    assert_equal "expiring", cert.compliance_status(today: Date.new(2026, 11, 2))
  end

  test "compliance_status: an automatic not found keeps the date status; a person's not found is fake" do
    cert = certificates(:juan_flagger) # expiring
    cert.record_authenticity!(status: :not_found, method: "automatic:national_cpr_foundation")
    assert cert.authenticity_flagged_for_review?
    assert_equal "expiring", cert.compliance_status

    cert.record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    assert_equal "fake", cert.compliance_status
    assert_equal "fake", cert.compliance_status(today: cert.expires_on + 1), "fake, whatever its dates"

    cert.record_authenticity!(status: :verified, method: "person", by: users(:manager))
    assert_equal "expiring", cert.compliance_status
  end

  test "enums use prefixes" do
    cert = certificates(:li_flagger)
    assert cert.expiry_printed?
    assert cert.source_import?
    assert_includes Certificate.source_import, cert
    assert_includes Certificate.expiry_none, certificates(:juan_osha30)
    assert_equal Certificate.none.to_a, [] # AR's .none is not shadowed
    assert Certificate.new.source_manual?
  end

  test "certificate_number is encrypted deterministically" do
    cert = certificates(:juan_osha30)
    assert_equal "30-1234567", cert.certificate_number
    assert_equal cert, Certificate.find_by(certificate_number: "30-1234567")
    raw = Certificate.connection.select_value("SELECT certificate_number FROM certificates WHERE id = #{cert.id}")
    assert_not_equal "30-1234567", raw
  end

  test "normalizes number and issuer" do
    cert = create_cert(completed_on: Date.new(2025, 1, 1), certificate_number: "  ", issued_by: "  Red  Cross ")
    assert_nil cert.certificate_number
    assert_equal "Red Cross", cert.issued_by
  end

  test "accepts allowed files and rejects others" do
    cert = create_cert(completed_on: Date.new(2025, 1, 1))
    cert.files.attach(io: StringIO.new("%PDF-1.4"), filename: "card.pdf", content_type: "application/pdf")
    assert cert.valid?
    assert_equal 1, cert.files.count

    bad = Certificate.new(crew_member: @member, certificate_type: @osha30, completed_on: Date.new(2025, 1, 1))
    bad.files.attach(io: StringIO.new("MZ"), filename: "virus.exe", content_type: "application/x-msdownload")
    assert_not bad.valid?
    assert_match "must be a PDF", bad.errors[:files].first
  end

  test "rejects files over 25 MB" do
    cert = Certificate.new(crew_member: @member, certificate_type: @osha30, completed_on: Date.new(2025, 1, 1))
    cert.files.attach(io: StringIO.new("x"), filename: "big.pdf", content_type: "application/pdf")
    cert.files.first.blob.byte_size = 26.megabytes
    assert_not cert.valid?
    assert_match "larger than 25 MB", cert.errors[:files].first
  end

  # juan_flagger expires about 10 days out and has a d30 send-log row per digest recipient.
  test "moving the expiry date past a logged threshold re-arms that alert" do
    cert = certificates(:juan_flagger)
    assert_equal 2, cert.expiry_notifications.count

    cert.update!(expires_on: Date.current + 400)

    assert_empty cert.expiry_notifications.reload
  end

  test "clearing the expiry date on a type that never expires removes the send log" do
    cert = certificates(:dave_cdl_a) # CDL A has no validity; its date was typed in
    cert.expiry_notifications.create!(threshold: :d30, recipient_email: "admin@example.com", sent_at: 1.day.ago)

    cert.update!(expires_on: nil)

    assert_predicate cert, :expiry_none?
    assert_empty cert.expiry_notifications.reload
  end

  test "an expiry change within the logged threshold keeps the log, so nothing is sent twice" do
    cert = certificates(:juan_flagger)

    cert.update!(expires_on: Date.current + 12) # still d30
    assert_equal 2, cert.expiry_notifications.count

    cert.update!(expires_on: Date.current + 3) # now d7: d30 was really reached
    assert_equal 2, cert.expiry_notifications.count
  end

  test "moving to a less urgent threshold drops only the more urgent rows" do
    cert = certificates(:juan_flagger)
    cert.expiry_notifications.create!(threshold: :d60, recipient_email: "admin@example.com", sent_at: 40.days.ago)

    cert.update!(expires_on: Date.current + 50) # d60

    assert_equal %w[d60], cert.expiry_notifications.reload.map(&:threshold)
  end

  test "correcting the type clears the send log, so the corrected type is alerted" do
    cert = create_cert(completed_on: Date.current - 300, expires_on: Date.current + 20) # manual date
    cert.expiry_notifications.create!(threshold: :d30, recipient_email: "admin@example.com", sent_at: 1.day.ago)

    cert.update!(certificate_type: certificate_types(:first_aid), expires_on: cert.expires_on.iso8601) # form resubmits the date

    assert_equal Date.current + 20, cert.expires_on
    assert_empty cert.expiry_notifications.reload
  end

  test "moving a certificate to another person clears the send log" do
    cert = certificates(:juan_flagger)
    assert_equal 2, cert.expiry_notifications.count

    cert.update!(crew_member: @member)

    assert_empty cert.expiry_notifications.reload
  end

  test "edits that leave the expiry date alone keep the send log" do
    cert = certificates(:juan_flagger)
    cert.update!(notes: "Card photo is blurry")

    assert_equal 2, cert.expiry_notifications.count
  end
end
