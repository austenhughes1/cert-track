require "test_helper"

class ProjectAssignmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tower = projects(:tower_2417)
    @new_member = CrewMember.create!(first_name: "Rosa", last_name: "Diaz", crew_role: crew_roles(:laborer), employer: "ABA Ventures")
  end

  # --- Access ---

  test "viewers can list crew but get 403 on create, update and destroy" do
    sign_in_as users(:viewer)
    assignment = project_assignments(:tower_juan)

    get project_assignments_path(@tower)
    assert_response :success
    assert_select "form[action=?]", project_assignments_path(@tower), count: 0
    assert_select "##{dom_id(assignment)} select", count: 0

    assert_no_difference -> { ProjectAssignment.count } do
      post project_assignments_path(@tower), params: { project_assignment: { crew_member_id: @new_member.id } }
    end
    assert_response :forbidden

    patch project_assignment_path(@tower, assignment), params: { project_assignment: { crew_role_id: crew_roles(:foreman).id } }
    assert_response :forbidden
    assert_nil assignment.reload.crew_role_id

    assert_no_difference -> { ProjectAssignment.count } do
      delete project_assignment_path(@tower, assignment)
    end
    assert_response :forbidden
  end

  # --- Index ---

  test "index shows each person's effective role and required types" do
    sign_in_as users(:manager)

    get project_assignments_path(@tower)

    assert_response :success
    assert_select "title", "Crew · 2417 · Tower 2417 Upgrade · CertTrack"
    assert_select "##{dom_id(project_assignments(:tower_li_chen))}" do
      assert_select "td", text: /Climber\s+\(project role\)/
      assert_select "td", text: "CLIMBER, FIRSTAID, FLAGGER, OSHA30"
      assert_select "select[name=?] option[selected][value=?]", "project_assignment[crew_role_id]", crew_roles(:climber).id.to_s
    end
    assert_select "##{dom_id(project_assignments(:tower_juan))}", text: /Climber\s+\(member's role\)/
    assert_select "##{dom_id(project_assignments(:tower_dave))} td", text: "CDLA, FIRSTAID, FLAGGER, OSHA30"
    assert_select "##{dom_id(project_assignments(:tower_maria))} td", text: "FIRSTAID, FLAGGER, OSHA30"
  end

  test "the add form offers only active members who are not yet assigned" do
    sign_in_as users(:manager)

    get project_assignments_path(@tower)

    options = css_select("select#project_assignment_crew_member_id option").map { |option| option["value"] }.compact_blank
    assert_equal [ @new_member.id.to_s ], options
    assert_select "option[value=?][data-role=?]", @new_member.id.to_s, "Laborer"
  end

  test "index runs a fixed number of queries however many people are assigned" do
    sign_in_as users(:manager)
    get project_assignments_path(@tower) # warm up
    count_queries = lambda do
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get project_assignments_path(@tower) }
      count
    end

    baseline = count_queries.call
    3.times do |i|
      member = CrewMember.create!(first_name: "Extra#{i}", last_name: "Hand", crew_role: crew_roles(:operator))
      @tower.project_assignments.create!(crew_member: member, crew_role: (crew_roles(:climber) if i.odd?))
    end

    assert_equal baseline, count_queries.call
  end

  test "index has an empty state" do
    project = Project.create!(name: "Nobody yet")
    sign_in_as users(:manager)

    get project_assignments_path(project)

    assert_response :success
    assert_select "p", text: "No crew assigned yet"
  end

  # --- Create ---

  test "assigns a member using their own role" do
    sign_in_as users(:manager)

    assert_difference -> { @tower.project_assignments.count } do
      post project_assignments_path(@tower), params: { project_assignment: {
        crew_member_id: @new_member.id, crew_role_id: "", starts_on: "2026-11-10", ends_on: ""
      } }
    end

    assert_redirected_to project_assignments_path(@tower)
    assert_equal "Assigned Rosa Diaz.", flash[:notice]
    assignment = @tower.project_assignments.find_by!(crew_member: @new_member)
    assert_nil assignment.crew_role_id
    assert_equal crew_roles(:laborer), assignment.effective_role
    assert_equal Date.new(2026, 11, 10), assignment.starts_on
    assert_nil assignment.ends_on
  end

  test "assigns a member with a role override for this project" do
    sign_in_as users(:admin)

    post project_assignments_path(@tower), params: { project_assignment: { crew_member_id: @new_member.id, crew_role_id: crew_roles(:climber).id } }

    assignment = @tower.project_assignments.find_by!(crew_member: @new_member)
    assert_equal crew_roles(:climber), assignment.crew_role
    assert_includes assignment.required_certificate_types, certificate_types(:climber)
  end

  test "rejects a duplicate assignment with a message" do
    sign_in_as users(:manager)

    assert_no_difference -> { ProjectAssignment.count } do
      post project_assignments_path(@tower), params: { project_assignment: { crew_member_id: crew_members(:juan_ortiz).id } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Crew member is already assigned to this project"
  end

  test "rejects inactive members, unknown members and bad dates" do
    sign_in_as users(:manager)

    post project_assignments_path(@tower), params: { project_assignment: { crew_member_id: crew_members(:sam_inactive).id } }
    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: /Crew member is inactive/

    post project_assignments_path(@tower), params: { project_assignment: { crew_member_id: CrewMember.maximum(:id) + 1 } }
    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Crew member must exist"

    post project_assignments_path(@tower), params: { project_assignment: {
      crew_member_id: @new_member.id, starts_on: "2026-12-10", ends_on: "2026-12-01"
    } }
    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Ends on can't be before the start date"

    assert_not ProjectAssignment.exists?(crew_member: [ crew_members(:sam_inactive), @new_member ], project: @tower)
  end

  # --- Update ---

  test "updates the role override and dates inline" do
    sign_in_as users(:manager)
    assignment = project_assignments(:tower_juan)

    patch project_assignment_path(@tower, assignment), params: { project_assignment: {
      crew_role_id: crew_roles(:foreman).id, starts_on: "2026-10-01", ends_on: "2027-01-31", crew_member_id: @new_member.id
    } }

    assert_redirected_to project_assignments_path(@tower)
    assignment.reload
    assert_equal crew_roles(:foreman), assignment.crew_role
    assert_equal Date.new(2027, 1, 31), assignment.ends_on
    assert_equal crew_members(:juan_ortiz), assignment.crew_member, "the member can't be swapped"
  end

  test "clearing the role override falls back to the member's role" do
    sign_in_as users(:manager)
    assignment = project_assignments(:tower_li_chen)

    patch project_assignment_path(@tower, assignment), params: { project_assignment: { crew_role_id: "" } }

    assert_nil assignment.reload.crew_role_id
    assert_equal crew_roles(:operator), assignment.effective_role
  end

  test "update shows errors on the row" do
    sign_in_as users(:manager)
    assignment = project_assignments(:tower_juan)

    patch project_assignment_path(@tower, assignment), params: { project_assignment: { starts_on: "2026-12-10", ends_on: "2026-12-01" } }

    assert_response :unprocessable_entity
    assert_select "tr[role=alert], td[role=alert]", text: /Ends on can't be before the start date/
    assert_nil assignment.reload.ends_on
  end

  test "an assignment from another project is a 404" do
    sign_in_as users(:manager)

    patch project_assignment_path(@tower, project_assignments(:closed_juan)), params: { project_assignment: { crew_role_id: "" } }

    assert_response :not_found
  end

  # --- Destroy ---

  test "removes a member from the project" do
    sign_in_as users(:manager)

    assert_difference -> { @tower.project_assignments.count }, -1 do
      delete project_assignment_path(@tower, project_assignments(:tower_maria))
    end

    assert_redirected_to project_assignments_path(@tower)
    assert_equal 303, response.status
    assert_equal "Removed Mari Garcia from 2417 · Tower 2417 Upgrade.", flash[:notice]
    assert CrewMember.exists?(crew_members(:maria_garcia).id)
  end
end
