require "test_helper"
require_relative "notifications_test_support"

class Notifications::DigestBuilderTest < ActiveSupport::TestCase
  include NotificationsTestSupport

  test "daily_items holds every current certificate of active crew within 90 days or expired" do
    items = Notifications::DigestBuilder.daily_items

    assert_equal %i[li_first_aid maria_first_aid juan_flagger dave_cdl_a juan_first_aid].map { |name| certificates(name) },
      items.map(&:certificate)
  end

  test "daily_items ignores superseded, inactive-member, never-expiring and far-off certificates" do
    certificate_ids = Notifications::DigestBuilder.daily_items.map { |item| item.certificate.id }

    %i[juan_flagger_old juan_first_aid_old sam_flagger juan_osha30 maria_osha30 juan_climber li_flagger dave_flagger].each do |name|
      assert_not_includes certificate_ids, certificates(name).id, name
    end
  end

  test "daily_items ignores the send log" do
    juan_flagger = Notifications::DigestBuilder.daily_items.find { |item| item.certificate == certificates(:juan_flagger) }

    assert juan_flagger, "juan_flagger was already sent at d30 but is still listed"
  end

  test "items carry the member, type, expiry, days left and most urgent threshold" do
    item = Notifications::DigestBuilder.daily_items.find { |each| each.certificate == certificates(:dave_cdl_a) }

    assert_kind_of Notifications::DigestItem, item
    assert_equal crew_members(:dave_miller), item.crew_member
    assert_equal certificate_types(:cdl_a), item.certificate_type
    assert_equal Date.current + 25, item.expires_on
    assert_equal 25, item.days_left
    assert_equal "d30", item.threshold

    expired = Notifications::DigestBuilder.daily_items.find { |each| each.certificate == certificates(:maria_first_aid) }
    assert_equal "expired", expired.threshold
    assert_predicate expired, :expired?
    assert_operator expired.days_left, :<, 0
  end

  test "thresholds follow the days left" do
    deactivate_fixture_crew!
    member = create_crew_member
    [ 91, 90, 45, 30, 7, 0, -1 ].each_with_index do |days, index|
      type = CertificateType.create!(name: "Type #{index}", code: "TYPE#{index}")
      create_certificate(member, expires_on: Date.current + days, type: type)
    end

    thresholds = Notifications::DigestBuilder.daily_items.to_h { |item| [ item.days_left, item.threshold ] }

    assert_equal({ -1 => "expired", 0 => "d7", 7 => "d7", 30 => "d30", 45 => "d60", 90 => "d90" }, thresholds)
  end

  test "each item lists the active projects that require its type for that person" do
    annex = Project.create!(name: "Annex 2420", code: "2420", status: :active)
    annex.project_requirements.create!(certificate_type: certificate_types(:flagger))
    annex.project_assignments.create!(crew_member: crew_members(:juan_ortiz))
    planned = Project.create!(name: "Planned 2430", code: "2430", status: :planned)
    planned.project_requirements.create!(certificate_type: certificate_types(:flagger))
    planned.project_assignments.create!(crew_member: crew_members(:juan_ortiz))

    items = Notifications::DigestBuilder.daily_items.index_by(&:certificate)

    assert_equal [ annex, projects(:tower_2417) ], items[certificates(:juan_flagger)].projects
    assert_equal [ projects(:tower_2417) ], items[certificates(:juan_first_aid)].projects
    assert_equal [ projects(:tower_2417) ], items[certificates(:dave_cdl_a)].projects, "CDL is required of operators"
  end

  test "projects use the role on the assignment, falling back to the member's role" do
    # Li Chen is an operator but works tower_2417 as a climber; the CDL requirement is operators only.
    li_cdl = create_certificate(crew_members(:li_chen), expires_on: Date.current + 20, type: certificate_types(:cdl_a))
    # Dave has no role on the assignment, so his member role (operator) applies.
    item = Notifications::DigestBuilder.daily_items.index_by(&:certificate)

    assert_equal [], item[li_cdl].projects
    assert_equal [ projects(:tower_2417) ], item[certificates(:dave_cdl_a)].projects
  end

  test "projects leave out assignments that have ended" do
    project_assignments(:tower_juan).update!(ends_on: Date.current - 1)
    project_assignments(:tower_dave).update!(ends_on: Date.current)

    items = Notifications::DigestBuilder.daily_items.index_by(&:certificate)

    assert_equal [], items[certificates(:juan_flagger)].projects
    assert_equal [ projects(:tower_2417) ], items[certificates(:dave_cdl_a)].projects, "an assignment ending today still counts"
  end

  test "items on no active project have an empty projects list" do
    deactivate_fixture_crew!
    certificate = create_certificate(create_crew_member, expires_on: Date.current + 10)

    assert_equal [ [ certificate, [] ] ], Notifications::DigestBuilder.daily_items.map { |item| [ item.certificate, item.projects ] }
  end

  test "weekly_items holds everything expiring within 30 days, expired included" do
    items = Notifications::DigestBuilder.weekly_items

    assert_equal %i[li_first_aid maria_first_aid juan_flagger dave_cdl_a].map { |name| certificates(name) }, items.map(&:certificate)
    assert_equal %w[expired expired d30 d30], items.map(&:threshold)
  end

  test "today can be given explicitly" do
    items = Notifications::DigestBuilder.weekly_items(today: Date.current + 40)

    assert_includes items.map(&:certificate), certificates(:juan_first_aid)
    assert_equal "expired", items.find { |item| item.certificate == certificates(:dave_cdl_a) }.threshold
  end

  test "runs a fixed number of queries however many people and projects there are" do
    baseline = count_queries { Notifications::DigestBuilder.daily_items }

    5.times do |index|
      member = create_crew_member(first_name: "Extra#{index}", crew_role: crew_roles(:operator))
      create_certificate(member, expires_on: Date.current + index)
      create_certificate(member, expires_on: Date.current + 40 + index, type: certificate_types(:cdl_a))
      projects(:tower_2417).project_assignments.create!(crew_member: member)
      project = Project.create!(name: "Extra project #{index}", status: :active)
      project.project_requirements.create!(certificate_type: certificate_types(:flagger))
      project.project_assignments.create!(crew_member: member)
    end

    assert_equal baseline, count_queries { Notifications::DigestBuilder.daily_items }
  end
end
