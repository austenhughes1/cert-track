require "test_helper"

class Compliance::OverviewTest < ActiveSupport::TestCase
  setup do
    @today = Date.current
    @tower = projects(:tower_2417)
  end

  def count_queries(&block)
    queries = []
    counter = lambda do |*, payload|
      queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ActiveRecord::Base.uncached(&block) }
    queries
  end

  # A second active project where Juan lacks the CDL everyone needs.
  def create_depot(code = "DEPOT")
    Project.create!(name: "Depot", code: code, ends_on: @today + 60).tap do |depot|
      depot.project_requirements.create!(certificate_type: certificate_types(:cdl_a))
      depot.project_assignments.create!(crew_member: crew_members(:juan_ortiz))
      depot.project_assignments.create!(crew_member: crew_members(:dave_miller))
    end
  end

  test "reports cover the given projects in order" do
    depot = create_depot
    overview = Compliance::Overview.new(Project.where(id: [ @tower, depot ]).ordered, today: @today)

    assert_equal [ depot, @tower ], overview.reports.map(&:project)
    assert_equal depot, overview.report_for(depot).project
    assert_equal @tower, overview.report_for(@tower.id).project
    assert_nil overview.report_for(projects(:closed_2390))
  end

  test "totals sum the project summaries" do
    create_depot
    overview = Compliance::Overview.new(Project.active, today: @today)

    # tower: 3 missing, 2 expired, 2 expiring, 1 lapses, 7 valid; depot: juan missing, dave expiring.
    assert_equal({ "missing" => 4, "fake" => 0, "expired" => 2, "expiring" => 3, "lapses_on_project" => 1, "valid" => 7 }, overview.totals)
  end

  test "a certificate a person confirmed fake counts as fake in totals, worst statuses, filters and gaps" do
    create_depot
    certificates(:dave_cdl_a).record_authenticity!(status: :not_found, method: "person", by: users(:manager)) # required on both
    certificates(:juan_osha30).record_authenticity!(status: :mismatch, method: "person", by: users(:manager))
    overview = Compliance::Overview.new(Project.active.ordered, today: @today)

    # tower: dave's CDL and juan's OSHA 30 fake; depot: dave's CDL fake, juan missing.
    assert_equal({ "missing" => 4, "fake" => 3, "expired" => 2, "expiring" => 1, "lapses_on_project" => 1, "valid" => 6 }, overview.totals)
    assert_equal "fake", overview.worst_status_by_crew_member[crew_members(:dave_miller).id]
    assert_equal "fake", overview.worst_status_by_crew_member[crew_members(:juan_ortiz).id]
    assert_equal [ crew_members(:juan_ortiz), crew_members(:dave_miller) ].map(&:id).to_set, overview.crew_member_ids_with(:fake)
    assert_equal [ [ "DEPOT", "Miller", "CDLA" ], [ "2417", "Miller", "CDLA" ], [ "2417", "Ortiz", "OSHA30" ] ],
      overview.gaps.select { |gap| gap.status == "fake" }.map { |gap| [ gap.project.code, gap.crew_member.last_name, gap.certificate_type.code ] }
    assert_equal 9, overview.gaps.size
  end

  test "a certificate only flagged for review counts by its dates everywhere" do
    create_depot
    certificates(:dave_cdl_a).record_authenticity!(status: :not_found, method: "automatic:national_cpr_foundation")
    certificates(:juan_osha30).record_authenticity!(status: :suspicious, method: "qr_link")
    overview = Compliance::Overview.new(Project.active.ordered, today: @today)

    assert_equal({ "missing" => 4, "fake" => 0, "expired" => 2, "expiring" => 3, "lapses_on_project" => 1, "valid" => 7 }, overview.totals)
    assert_equal "missing", overview.worst_status_by_crew_member[crew_members(:dave_miller).id]
    assert_empty overview.crew_member_ids_with(:fake)
    assert_includes overview.crew_member_ids_with(:expiring), crew_members(:dave_miller).id
    assert_equal 6, overview.gaps.size
    assert_not_includes overview.gaps.map(&:certificate), certificates(:dave_cdl_a)
  end

  test "only active projects when given Project.active" do
    overview = Compliance::Overview.new(Project.active, today: @today)

    assert_equal [ @tower ], overview.reports.map(&:project)
    assert_equal Compliance::ProjectReport.new(@tower, today: @today).summary, overview.totals
  end

  test "worst_status_by_crew_member takes the worst cell across projects" do
    overview = Compliance::Overview.new(Project.active, today: @today)
    expected = { juan_ortiz: "expiring", maria_garcia: "expired", li_chen: "expired", dave_miller: "missing" }

    assert_equal expected.transform_keys { |name| crew_members(name).id }, overview.worst_status_by_crew_member

    create_depot
    assert_equal "missing", Compliance::Overview.new(Project.active, today: @today).worst_status_by_crew_member[crew_members(:juan_ortiz).id]
  end

  test "members with nothing required are left out of worst_status_by_crew_member" do
    project = Project.create!(name: "No requirements")
    project.project_assignments.create!(crew_member: crew_members(:juan_ortiz))

    assert_equal({}, Compliance::Overview.new([ project ], today: @today).worst_status_by_crew_member)
  end

  test "crew_member_ids_with" do
    overview = Compliance::Overview.new(Project.active, today: @today)
    ids = ->(*names) { names.map { |name| crew_members(name).id }.to_set }

    assert_equal ids.(:maria_garcia, :li_chen), overview.crew_member_ids_with("expired")
    assert_equal ids.(:maria_garcia, :li_chen, :dave_miller), overview.crew_member_ids_with(:missing)
    assert_equal ids.(:juan_ortiz, :dave_miller), overview.crew_member_ids_with("expiring")
    assert_equal ids.(:juan_ortiz), overview.crew_member_ids_with("lapses_on_project")
    assert_equal ids.(:juan_ortiz, :maria_garcia, :li_chen, :dave_miller), overview.crew_member_ids_with("valid")
    assert_kind_of Set, overview.crew_member_ids_with("expired")
  end

  test "an ended assignment drops out of totals, filters and gaps" do
    before = Compliance::Overview.new(Project.active, today: @today)
    left = CrewMember.create!(first_name: "Rux", last_name: "Leaver")
    @tower.project_assignments.create!(crew_member: left, starts_on: @today - 30, ends_on: @today - 3)
    overview = Compliance::Overview.new(Project.active, today: @today)

    assert_equal before.totals, overview.totals
    assert_not_includes overview.crew_member_ids_with(:missing), left.id
    assert_nil overview.worst_status_by_crew_member[left.id]
    assert_not_includes overview.gaps.map(&:crew_member), left
  end

  test "gaps across projects" do
    create_depot
    gaps = Compliance::Overview.new(Project.active.ordered, today: @today).gaps

    assert_equal 6, gaps.size
    assert_equal [ "DEPOT", "Ortiz", "CDLA", "missing" ],
      gaps.first.then { |gap| [ gap.project.code, gap.crew_member.last_name, gap.certificate_type.code, gap.status ] }
  end

  test "query count does not grow with the number of projects" do
    single = count_queries { Compliance::Overview.new(Project.active, today: @today).totals }
    3.times { |i| create_depot("DEPOT#{i}") }
    many = count_queries do
      overview = Compliance::Overview.new(Project.active, today: @today)
      overview.totals
      overview.worst_status_by_crew_member
      overview.gaps
    end

    assert_equal single.size, many.size, many.join("\n")
    assert_operator many.size, :<=, 5
  end

  test "no projects" do
    overview = Compliance::Overview.new(Project.none, today: @today)

    assert_equal [], overview.reports
    assert_equal Compliance::STATUSES.index_with(0), overview.totals
    assert_equal({}, overview.worst_status_by_crew_member)
    assert_empty overview.crew_member_ids_with("missing")
  end
end
