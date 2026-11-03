require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  # On tower_2417 (the only active fixture project): expired maria + li first aid;
  # missing maria flagger, li climber, dave first aid; expiring juan flagger, dave CDL;
  # lapses juan first aid; valid the other 7 cells.
  TOWER_TOTALS = { "expired" => 2, "missing" => 3, "expiring" => 2, "lapses_on_project" => 1, "valid" => 7 }.freeze

  test "requires sign-in" do
    get root_path
    assert_redirected_to new_session_path
  end

  test "every role sees the dashboard" do
    %i[viewer manager admin].each do |role|
      sign_in_as users(role)
      get root_path
      assert_response :success, "#{role} should see the dashboard"
      assert_select "title", "Dashboard · CertTrack"
      assert_select "h1", "Dashboard"
      sign_out
    end
  end

  test "tiles count required cells on active projects and link to the crew filter" do
    sign_in_as users(:viewer)
    get root_path

    %w[expired missing expiring lapses_on_project].each do |status|
      assert_select "a#tile_#{status}[href=?]", crew_members_path(status: status) do
        assert_select "[data-count]", TOWER_TOTALS.fetch(status).to_s
      end
    end
    assert_select "#tile_expired", /2 people/
    assert_select "#tile_lapses_on_project", /1 person/
  end

  test "review queue tile counts items waiting for review and has no link yet" do
    sign_in_as users(:viewer)
    get root_path

    assert_select "#tile_review_queue [data-count]", ImportItem.needs_review.count.to_s
    assert_select "#tile_review_queue [data-count]", "1"
    assert_select "a#tile_review_queue", count: 0
  end

  test "next expirations lists current certificates of active crew, soonest first" do
    sign_in_as users(:viewer)
    get root_path

    expected = %i[juan_flagger dave_cdl_a juan_first_aid juan_climber li_flagger dave_flagger].map { |name| certificates(name) }
    rows = css_select("#upcoming_expirations tbody tr").map { |row| row["id"] }
    assert_equal expected.map { |certificate| "upcoming_certificate_#{certificate.id}" }, rows

    # Never-expiring, already expired, superseded and inactive members' certificates stay out.
    %i[juan_osha30 maria_first_aid li_first_aid juan_flagger_old sam_flagger].each do |name|
      assert_select "#upcoming_certificate_#{certificates(name).id}", count: 0
    end

    juan_flagger = certificates(:juan_flagger)
    assert_select "#upcoming_certificate_#{juan_flagger.id}" do
      assert_select "a[href=?]", crew_member_path(crew_members(:juan_ortiz)), text: "Juan Ortiz"
      assert_select "a[href=?]", crew_member_certificate_path(crew_members(:juan_ortiz), juan_flagger), text: "Flagger"
      assert_select "td", text: juan_flagger.expires_on.strftime("%b %-d, %Y")
      assert_select "td", text: (juan_flagger.expires_on - Date.current).to_i.to_s
    end
  end

  test "next expirations names the active projects that require the type of that person" do
    tower = projects(:tower_2417)
    tower_2420 = Project.create!(name: "Tower 2420", code: "2420", status: :active, ends_on: Date.current + 90)
    tower_2420.project_requirements.create!(certificate_type: certificate_types(:flagger), crew_role: crew_roles(:operator))
    tower_2420.project_assignments.create!(crew_member: crew_members(:dave_miller))
    tower_2420.project_assignments.create!(crew_member: crew_members(:juan_ortiz))
    # tower_2417 requires CDL A of operators only; Juan is a climber.
    juan_cdl = crew_members(:juan_ortiz).certificates.create!(certificate_type: certificate_types(:cdl_a),
      completed_on: Date.current - 100, expires_on: Date.current + 50)

    sign_in_as users(:viewer)
    get root_path

    assert_equal [ "2417", "2420" ], needed_on(certificates(:dave_flagger))
    assert_equal [ "2417" ], needed_on(certificates(:juan_flagger)) # 2420's flagger rule is operators only
    assert_equal [ "2417" ], needed_on(certificates(:dave_cdl_a))
    assert_equal [ "2417" ], needed_on(certificates(:juan_first_aid)) # closed_2390 also requires it, but is closed
    assert_empty needed_on(juan_cdl)
    assert_select "#upcoming_certificate_#{juan_cdl.id}", text: /—/

    assert_select "#upcoming_certificate_#{certificates(:dave_flagger).id} a[href=?]", project_compliance_path(tower)
    assert_select "#upcoming_certificate_#{certificates(:dave_flagger).id} a[href=?]", project_compliance_path(tower_2420)
  end

  test "next expirations stops at 20" do
    juan = crew_members(:juan_ortiz)
    16.times do |index|
      type = CertificateType.create!(name: "Extra type #{index}", code: "EXTRA#{index}")
      juan.certificates.create!(certificate_type: type, completed_on: Date.current - 10, expires_on: Date.current + 800 + index)
    end

    sign_in_as users(:viewer)
    get root_path

    assert_select "#upcoming_expirations tbody tr", count: DashboardController::UPCOMING_LIMIT
    assert_select "#upcoming_expirations h2", "Next 20 expirations"
  end

  test "active projects list shows each project's summary and matrix link" do
    tower = projects(:tower_2417)
    sign_in_as users(:viewer)
    get root_path

    assert_select "#active_projects tr#dashboard_project_#{tower.id}" do
      assert_select "a[href=?]", project_path(tower), text: "2417 · Tower 2417 Upgrade"
      assert_select "a[href=?]", project_compliance_path(tower), text: "Matrix"
      TOWER_TOTALS.each { |status, count| assert_select "td[data-status=#{status}]", count.to_s }
      assert_select "td", "4" # crew
    end
    assert_select "#dashboard_project_#{projects(:closed_2390).id}", count: 0
  end

  test "empty states when nothing is active or due" do
    projects(:tower_2417).closed!
    Certificate.update_all(expires_on: nil)

    sign_in_as users(:viewer)
    get root_path

    assert_response :success
    assert_select "#getting_started", count: 0
    assert_select "#active_projects", /No active projects/
    assert_select "#upcoming_expirations", /Nothing is due to expire/
    assert_select "#tile_expired [data-count]", "0"
    assert_select "#tile_missing [data-count]", "0"
  end

  test "a fresh install shows next steps instead of empty numbers" do
    wipe_tracker_data!
    CertificateType.update_all(validity_months: nil) # as seeded
    sign_in_as users(:admin)
    get root_path

    assert_response :success
    assert_select "#getting_started" do
      assert_select "li", 3
      assert_select "a[href=?]", certificate_types_path
      assert_select "a[href=?]", new_crew_member_path
      assert_select "a[href=?]", new_project_path
    end
    assert_select "#tile_expired", count: 0
    assert_select "#upcoming_expirations", count: 0
    assert_select "#active_projects", count: 0
  end

  test "the master list step is done once a type has a validity period" do
    wipe_tracker_data!
    CertificateType.update_all(validity_months: nil)
    sign_in_as users(:admin)

    get root_path
    assert_select "#getting_started a[href=?]", certificate_types_path

    certificate_types(:flagger).update!(validity_months: 36)
    get root_path
    assert_select "#getting_started a[href=?]", certificate_types_path, count: 0
  end

  test "viewers get next steps without action links" do
    wipe_tracker_data!
    CertificateType.update_all(validity_months: nil)
    sign_in_as users(:viewer)
    get root_path

    assert_select "#getting_started", /An admin or manager needs to finish these steps/
    assert_select "#getting_started a", count: 0
  end

  test "managers can add crew and projects but not edit the master list from the steps" do
    wipe_tracker_data!
    CertificateType.update_all(validity_months: nil)
    sign_in_as users(:manager)
    get root_path

    assert_select "#getting_started a[href=?]", new_crew_member_path
    assert_select "#getting_started a[href=?]", new_project_path
    assert_select "#getting_started a[href=?]", certificate_types_path, count: 0
  end

  test "with crew but no projects it shows the remaining step and the numbers" do
    ProjectAssignment.delete_all
    ProjectRequirement.delete_all
    Project.delete_all
    sign_in_as users(:manager)
    get root_path

    assert_select "#getting_started a[href=?]", new_project_path
    assert_select "#getting_started a[href=?]", new_crew_member_path, count: 0
    assert_select "#tile_expired [data-count]", "0"
    assert_select "#upcoming_expirations tbody tr", 6
  end

  test "query count does not grow with crew, certificates or projects" do
    sign_in_as users(:viewer)
    get root_path # warm up
    baseline = count_queries { get root_path }
    assert_operator baseline, :>, 5

    tower = projects(:tower_2417)
    other = Project.create!(name: "Tower 2421", code: "2421", status: :active, ends_on: Date.current + 200)
    other.project_requirements.create!(certificate_type: certificate_types(:flagger))
    5.times do |index|
      member = CrewMember.create!(first_name: "Extra", last_name: "Hand #{index}", crew_role: crew_roles(:operator))
      [ tower, other ].each { |project| project.project_assignments.create!(crew_member: member) }
      %i[flagger first_aid cdl_a].each do |type|
        member.certificates.create!(certificate_type: certificate_types(type), completed_on: Date.current - 30,
          expires_on: Date.current + 40 + index)
      end
    end

    assert_equal baseline, count_queries { get root_path }
    assert_select "#upcoming_expirations tbody tr", 20
    assert_select "#active_projects tbody tr", 2
  end

  private
    def needed_on(certificate)
      css_select("#upcoming_certificate_#{certificate.id} td:last-child a").map { |link| link.text.strip }
    end

    # Integration requests share the test's pinned connection, whose query cache
    # survives between requests until a write, so clear it to count real queries.
    def count_queries(&block)
      ActiveRecord::Base.connection_pool.clear_query_cache
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    # A fresh install: the seeded master list and users, nothing else.
    def wipe_tracker_data!
      ImportItem.update_all(certificate_id: nil, duplicate_of_id: nil)
      Certificate.update_all(import_item_id: nil)
      ImportBatch.delete_all # items cascade
      ExpiryNotification.delete_all
      Certificate.delete_all
      ProjectAssignment.delete_all
      ProjectRequirement.delete_all
      Project.delete_all
      CrewMember.delete_all
    end
end
