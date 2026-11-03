require "test_helper"

class CrewRolesControllerTest < ActionDispatch::IntegrationTest
  test "anonymous users are sent to sign in" do
    get crew_roles_path
    assert_redirected_to new_session_path
  end

  test "viewers get 403 on every write action and nothing changes" do
    sign_in_as users(:viewer)
    role = CrewRole.create!(name: "Rigger")

    get new_crew_role_path
    assert_response :forbidden

    assert_no_difference -> { CrewRole.count } do
      post crew_roles_path, params: { crew_role: { name: "Sneaky" } }
    end
    assert_response :forbidden

    get edit_crew_role_path(role)
    assert_response :forbidden

    patch crew_role_path(role), params: { crew_role: { name: "Renamed" } }
    assert_response :forbidden
    assert_equal "Rigger", role.reload.name

    assert_no_difference -> { CrewRole.count } do
      delete crew_role_path(role)
    end
    assert_response :forbidden
  end

  test "index lists roles with usage counts for everyone, edit controls for editors only" do
    sign_in_as users(:viewer)

    get crew_roles_path

    assert_response :success
    assert_select "title", "Crew roles · CertTrack"
    assert_equal %w[Climber Foreman Laborer Operator], css_select("tbody tr td:first-child").map { |td| td.text.strip }
    climber = crew_roles(:climber)
    # Juan holds it; one requirement (tower_climber_climbers); Li Chen's assignment overrides to it.
    assert_select "tr##{dom_id(climber)}" do
      assert_select "a[href=?]", crew_members_path(crew_role_id: climber.id), text: "Climber"
      assert_select "td.text-right", text: "1", count: 3
    end
    assert_select "a", text: "Add role", count: 0
    assert_select "a", text: "Edit", count: 0

    sign_out
    sign_in_as users(:manager)
    get crew_roles_path
    assert_select "a", text: "Add role"
    assert_select "tr##{dom_id(crew_roles(:foreman))}", text: /In use/
  end

  test "index shows an empty state" do
    sign_in_as users(:manager)
    CrewMember.update_all(crew_role_id: nil)
    ProjectAssignment.update_all(crew_role_id: nil)
    ProjectRequirement.where.not(crew_role_id: nil).delete_all
    CrewRole.delete_all

    get crew_roles_path

    assert_select "p", text: "No roles yet"
  end

  test "new renders the form" do
    sign_in_as users(:manager)

    get new_crew_role_path

    assert_response :success
    assert_select "title", "Add role · CertTrack"
    assert_select "input#crew_role_name"
  end

  test "create adds a role" do
    sign_in_as users(:manager)

    assert_difference -> { CrewRole.count }, 1 do
      post crew_roles_path, params: { crew_role: { name: "  Driver " } }
    end

    assert_redirected_to crew_roles_path
    assert_equal "Added the Driver role.", flash[:notice]
    assert CrewRole.exists?(name: "Driver")
  end

  test "create shows validation errors, including case-insensitive duplicates" do
    sign_in_as users(:admin)

    assert_no_difference -> { CrewRole.count } do
      post crew_roles_path, params: { crew_role: { name: "climber" } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Name has already been taken"

    post crew_roles_path, params: { crew_role: { name: "" } }
    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Name can't be blank"
  end

  test "edit and update rename a role" do
    sign_in_as users(:manager)
    role = crew_roles(:laborer)

    get edit_crew_role_path(role)
    assert_response :success
    assert_select "title", "Edit role · CertTrack"

    patch crew_role_path(role), params: { crew_role: { name: "General Laborer" } }

    assert_redirected_to crew_roles_path
    assert_equal "General Laborer", role.reload.name
    assert_equal role, crew_members(:sam_inactive).reload.crew_role
  end

  test "update shows validation errors" do
    sign_in_as users(:manager)

    patch crew_role_path(crew_roles(:laborer)), params: { crew_role: { name: "Foreman" } }

    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Name has already been taken"
    assert_equal "Laborer", crew_roles(:laborer).reload.name
  end

  test "destroy deletes an unused role" do
    sign_in_as users(:manager)
    role = CrewRole.create!(name: "Rigger")

    assert_difference -> { CrewRole.count }, -1 do
      delete crew_role_path(role)
    end

    assert_redirected_to crew_roles_path
    assert_equal "Deleted the Rigger role.", flash[:notice]
  end

  test "destroy refuses a role in use" do
    sign_in_as users(:manager)

    assert_no_difference -> { CrewRole.count } do
      delete crew_role_path(crew_roles(:foreman))
    end

    assert_redirected_to crew_roles_path
    assert_match "Can't delete the Foreman role", flash[:alert]
  end

  test "destroy refuses a role used only by a project requirement" do
    sign_in_as users(:manager)
    role = CrewRole.create!(name: "Rigger")
    projects(:tower_2417).project_requirements.create!(certificate_type: certificate_types(:flagger), crew_role: role)

    assert_no_difference -> { CrewRole.count } do
      delete crew_role_path(role)
    end

    assert_match "Can't delete the Rigger role", flash[:alert]
  end
end
