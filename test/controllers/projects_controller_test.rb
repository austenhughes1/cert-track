require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tower = projects(:tower_2417)
    @closed = projects(:closed_2390)
  end

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  # A project with requirements and crew, so the index has more to compute.
  def create_staffed_project(code)
    project = Project.create!(name: "Site #{code}", code: code, status: :active, ends_on: Date.current + 60)
    project.project_requirements.create!(certificate_type: certificate_types(:osha30))
    project.project_requirements.create!(certificate_type: certificate_types(:climber), crew_role: crew_roles(:climber))
    project.project_assignments.create!(crew_member: crew_members(:juan_ortiz))
    project.project_assignments.create!(crew_member: crew_members(:dave_miller), crew_role: crew_roles(:climber))
    project
  end

  # --- Access ---

  test "anonymous users are sent to sign in" do
    get projects_path
    assert_redirected_to new_session_path
  end

  test "viewers can read but get 403 on every write action" do
    sign_in_as users(:viewer)

    get projects_path
    assert_response :success
    get project_path(@tower)
    assert_response :success

    get new_project_path
    assert_response :forbidden
    get edit_project_path(@tower)
    assert_response :forbidden

    assert_no_difference -> { Project.count } do
      post projects_path, params: { project: { name: "Sneaky" } }
    end
    assert_response :forbidden

    patch project_path(@tower), params: { project: { status: "closed" } }
    assert_response :forbidden
    assert @tower.reload.active?

    empty = Project.create!(name: "Empty")
    assert_no_difference -> { Project.count } do
      delete project_path(empty)
    end
    assert_response :forbidden
  end

  test "viewers see no edit controls" do
    sign_in_as users(:viewer)

    get projects_path
    assert_select "a[href=?]", new_project_path, count: 0

    get project_path(@tower)
    assert_select "a[href=?]", edit_project_requirements_path(@tower), count: 0
    assert_select "a[href=?]", edit_project_path(@tower), count: 0
    assert_select "a[href=?]", project_compliance_path(@tower)
  end

  # --- Index ---

  test "index lists planned and active projects by default with compliance counts" do
    planned = Project.create!(name: "Future Site", code: "2430", status: :planned)
    sign_in_as users(:viewer)

    get projects_path

    assert_response :success
    assert_select "title", "Projects · CertTrack"
    assert_select "##{dom_id(@tower)}" do
      assert_select "a[href=?]", project_path(@tower), text: "2417 · Tower 2417 Upgrade"
      assert_select "td", text: "Prime Wireless"
      assert_select "td", text: "4" # active crew
      assert_select "[data-status=valid]", text: /7 valid/
      assert_select "[data-status=missing]", text: /3 missing/
      assert_select "[data-status=expired]", text: /2 expired/
      assert_select "[data-status=expiring]", text: /2 expiring/
      assert_select "[data-status=lapses_on_project]", text: /1 lapses on project/
    end
    assert_select "##{dom_id(planned)}", text: /No requirements/
    assert_select "##{dom_id(@closed)}", count: 0
  end

  test "index filters by status" do
    sign_in_as users(:manager)

    get projects_path(status: "closed")
    assert_select "##{dom_id(@closed)}"
    assert_select "##{dom_id(@tower)}", count: 0

    get projects_path(status: "all")
    assert_select "##{dom_id(@closed)}"
    assert_select "##{dom_id(@tower)}"

    get projects_path(status: "bogus")
    assert_select "##{dom_id(@tower)}"
    assert_select "##{dom_id(@closed)}", count: 0
  end

  test "index shows an empty state" do
    sign_in_as users(:manager)

    get projects_path(status: "planned")

    assert_response :success
    assert_select "p", text: "No planned projects"
  end

  test "index runs a fixed number of queries however many projects there are" do
    sign_in_as users(:viewer)
    get projects_path # warm up

    baseline = count_queries { get projects_path }
    create_staffed_project("3001")
    create_staffed_project("3002")
    create_staffed_project("3003")
    more = count_queries { get projects_path }

    assert_response :success
    assert_select "tbody tr", 4
    assert_equal baseline, more
  end

  # --- Show ---

  test "show lists requirements with role limits and crew with effective roles" do
    sign_in_as users(:manager)

    get project_path(@tower)

    assert_response :success
    assert_select "title", "2417 · Tower 2417 Upgrade · CertTrack"
    assert_select "##{dom_id(certificate_types(:osha30), :requirement)}", text: /Everyone/
    assert_select "##{dom_id(certificate_types(:climber), :requirement)}", text: /Climber only/
    assert_select "##{dom_id(certificate_types(:cdl_a), :requirement)}", text: /Operator only/
    assert_select "##{dom_id(project_assignments(:tower_li_chen))}", text: /Climber\s+\(project role\)/
    assert_select "##{dom_id(project_assignments(:tower_juan))}", text: /Climber\s+\(member's role\)/
    assert_select "##{dom_id(project_assignments(:tower_maria))} [data-status=expired]"
    assert_select "a[href=?]", project_compliance_path(@tower)
    assert_select "a[href=?]", project_packet_path(@tower)
    assert_select "a[href=?]", edit_project_requirements_path(@tower)
    assert_select "a[href=?]", project_assignments_path(@tower)
    # Has crew and requirements, so it can only be closed, not deleted.
    assert_select "form[action=?] input[name=_method][value=delete]", project_path(@tower), count: 0
    assert_select "button", text: "Close project"
  end

  test "show lists the project's gaps" do
    sign_in_as users(:viewer)

    get project_path(@tower)

    assert_select "ul[aria-label=?] li", "Missing and expired certificates", 5 # 3 missing + 2 expired
    assert_select "ul[aria-label=?] li", "Missing and expired certificates", text: /Garcia, Maria\s+· Flagger/
  end

  test "show has empty states for a new project" do
    project = Project.create!(name: "Blank Site")
    sign_in_as users(:manager)

    get project_path(project)

    assert_response :success
    assert_select "p", text: "No required certificates yet"
    assert_select "p", text: "No crew assigned yet"
    assert_select "form[action=?] input[name=_method][value=delete]", project_path(project)
  end

  test "show marks inactive crew instead of checking them" do
    sign_in_as users(:viewer)

    get project_path(@closed)

    assert_select "##{dom_id(project_assignments(:closed_sam))}", text: /Inactive/
  end

  # --- Create / update ---

  test "managers create a project" do
    sign_in_as users(:manager)

    get new_project_path
    assert_response :success
    assert_select "title", "New project · CertTrack"

    assert_difference -> { Project.count } do
      post projects_path, params: { project: {
        name: "Ridge 2421", code: " 2421 ", client: "Prime Wireless", location: "Boulder, CO",
        starts_on: "2026-12-01", ends_on: "2027-03-01", status: "planned"
      } }
    end

    project = Project.order(:id).last
    assert_redirected_to project_path(project)
    assert_equal "2421", project.code
    assert project.planned?
    assert_equal Date.new(2027, 3, 1), project.ends_on
  end

  test "create shows validation errors" do
    sign_in_as users(:admin)

    assert_no_difference -> { Project.count } do
      post projects_path, params: { project: { name: "", code: "2417", starts_on: "2027-01-10", ends_on: "2027-01-01" } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Name can't be blank"
    assert_select "#error_explanation li", text: "Code has already been taken"
    assert_select "#error_explanation li", text: "Ends on can't be before the start date"
  end

  test "update saves changes" do
    sign_in_as users(:manager)

    get edit_project_path(@tower)
    assert_response :success

    patch project_path(@tower), params: { project: { client: "New GC", ends_on: (Date.current + 200).iso8601 } }

    assert_redirected_to project_path(@tower)
    assert_equal "New GC", @tower.reload.client
    assert_equal Date.current + 200, @tower.ends_on
  end

  test "update shows validation errors" do
    sign_in_as users(:manager)

    patch project_path(@tower), params: { project: { name: " ", status: "archived" } }

    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Name can't be blank"
    assert_select "#error_explanation li", text: /Status/
    assert_equal "Tower 2417 Upgrade", @tower.reload.name
  end

  test "close project button sets the status to closed" do
    sign_in_as users(:manager)

    patch project_path(@tower), params: { project: { status: "closed" } }

    assert_redirected_to project_path(@tower)
    assert_equal "2417 · Tower 2417 Upgrade is now closed.", flash[:notice]
    assert @tower.reload.closed?
  end

  # --- Destroy ---

  test "deletes a project with no crew or requirements" do
    project = Project.create!(name: "Mistake")
    sign_in_as users(:manager)

    assert_difference -> { Project.count }, -1 do
      delete project_path(project)
    end

    assert_redirected_to projects_path
    assert_equal 303, response.status
  end

  test "refuses to delete a project with assignments or requirements" do
    with_requirement = Project.create!(name: "Has requirement")
    with_requirement.project_requirements.create!(certificate_type: certificate_types(:osha30))
    sign_in_as users(:admin)

    [ @tower, with_requirement ].each do |project|
      assert_no_difference -> { Project.count } do
        delete project_path(project)
      end
      assert_redirected_to project_path(project)
      assert_match "Close it instead", flash[:alert]
    end
    assert_equal 5, @tower.project_requirements.count
  end

  test "refuses to delete a project with past packets: they are the record of what was sent" do
    project = Project.create!(name: "Packet sent")
    build = project.packet_builds.create!(built_at: 2.days.ago, packet_filename: "packet-sent.zip")
    sign_in_as users(:admin)

    get project_path(project)
    assert_select "button", text: "Delete", count: 0

    assert_no_difference -> { Project.count } do
      delete project_path(project)
    end
    assert_redirected_to project_path(project)
    assert_match "past packets", flash[:alert]
    assert_match "Close it instead", flash[:alert]
    assert PacketBuild.exists?(build.id)
  end

  test "the details say when a built packet's zip has expired" do
    @tower.update!(packet_built_at: Time.zone.local(2026, 10, 20, 9))
    sign_in_as users(:viewer)

    get project_path(@tower)
    assert_select "#packet_status", text: "Built Oct 20, 2026 (zip expired)"

    @tower.packet.attach(io: StringIO.new("zip"), filename: "2417-packet.zip", content_type: "application/zip")
    get project_path(@tower)
    assert_select "#packet_status", text: "Built Oct 20, 2026"
  end
end
