require "test_helper"

class ProjectRequirementsControllerTest < ActionDispatch::IntegrationTest
  setup { @tower = projects(:tower_2417) }

  def key(type_fixture, role_fixture = nil)
    Projects::UpdateRequirements.key(certificate_types(type_fixture).id, role_fixture && crew_roles(role_fixture).id)
  end

  def tower_keys
    @tower.project_requirements.reload.map { |requirement| Projects::UpdateRequirements.key(requirement.certificate_type_id, requirement.crew_role_id) }.sort
  end

  # --- Access ---

  test "viewers get 403 on edit, update and copy" do
    sign_in_as users(:viewer)
    target = Project.create!(name: "Target")

    get edit_project_requirements_path(@tower)
    assert_response :forbidden

    assert_no_difference -> { ProjectRequirement.count } do
      patch project_requirements_path(@tower), params: { requirement_keys: [ "" ] }
    end
    assert_response :forbidden

    assert_no_difference -> { ProjectRequirement.count } do
      post copy_project_requirements_path(target), params: { source_project_id: @tower.id }
    end
    assert_response :forbidden
  end

  # --- Editor grid ---

  test "edit shows active types by Everyone and each role with current requirements ticked" do
    sign_in_as users(:manager)

    get edit_project_requirements_path(@tower)

    assert_response :success
    assert_select "title", "Requirements · 2417 · Tower 2417 Upgrade · CertTrack"
    assert_select "thead th", text: "Everyone"
    CrewRole.find_each { |role| assert_select "thead th", text: "#{role.name} only" }

    checked = css_select("input[type=checkbox][name='requirement_keys[]'][checked]").map { |box| box["value"] }.sort
    assert_equal tower_keys, checked
    assert_select "input[type=checkbox][value=?]", key(:climber, :foreman)
    assert_select "input[type=checkbox][value=?]:not([checked])", key(:climber, :foreman)
    # Retired types are hidden unless the project still requires them.
    assert_select "##{dom_id(certificate_types(:retired_hazwoper), :requirements)}", count: 0
    # Copy sources: other projects with requirements.
    assert_select "select#source_project_id option[value=?]", projects(:closed_2390).id.to_s, text: /2390 · Rooftop 2390 \(2 requirements\)/
    assert_select "select#source_project_id option[value=?]", @tower.id.to_s, count: 0
  end

  test "edit keeps a retired type that the project still requires" do
    @tower.project_requirements.create!(certificate_type: certificate_types(:retired_hazwoper))
    sign_in_as users(:manager)

    get edit_project_requirements_path(@tower)

    assert_select "##{dom_id(certificate_types(:retired_hazwoper), :requirements)}", text: /Retired/ do
      assert_select "input[value=?][checked]", key(:retired_hazwoper)
    end
  end

  test "update creates and removes Everyone and role-specific rows" do
    sign_in_as users(:manager)
    keys = tower_keys - [ key(:flagger), key(:cdl_a, :operator) ] + [ key(:cdl_a), key(:climber, :foreman) ]

    patch project_requirements_path(@tower), params: { requirement_keys: [ "" ] + keys }

    assert_redirected_to project_path(@tower)
    assert_equal "Requirements saved: 2 added, 2 removed.", flash[:notice]
    assert_equal keys.sort, tower_keys
    assert @tower.project_requirements.exists?(certificate_type: certificate_types(:cdl_a), crew_role: nil)
    assert @tower.project_requirements.exists?(certificate_type: certificate_types(:climber), crew_role: crew_roles(:foreman))
    assert @tower.project_requirements.exists?(certificate_type: certificate_types(:climber), crew_role: crew_roles(:climber))
    assert_not @tower.project_requirements.exists?(certificate_type: certificate_types(:flagger))
  end

  test "update with nothing ticked clears the project's requirements" do
    sign_in_as users(:admin)

    assert_difference -> { ProjectRequirement.count }, -5 do
      patch project_requirements_path(@tower), params: { requirement_keys: [ "" ] }
    end

    assert_redirected_to project_path(@tower)
    assert_empty tower_keys
    assert_equal 2, projects(:closed_2390).project_requirements.count
  end

  test "update with the same boxes reports no changes" do
    sign_in_as users(:manager)

    assert_no_difference -> { ProjectRequirement.count } do
      patch project_requirements_path(@tower), params: { requirement_keys: [ "" ] + tower_keys }
    end

    assert_equal "No changes to requirements.", flash[:notice]
  end

  test "update ignores malformed keys" do
    sign_in_as users(:manager)

    patch project_requirements_path(@tower), params: { requirement_keys: [ "", "nope", "1:2:3" ] + tower_keys }

    assert_redirected_to project_path(@tower)
    assert_equal 5, @tower.project_requirements.count
  end

  test "update without the keys param is a bad request" do
    sign_in_as users(:manager)

    assert_no_difference -> { ProjectRequirement.count } do
      patch project_requirements_path(@tower)
    end

    assert_response :bad_request
  end

  # --- Copy ---

  test "copy merges another project's requirements without duplicates" do
    target = Project.create!(name: "Target", code: "2499")
    target.project_requirements.create!(certificate_type: certificate_types(:osha30))
    sign_in_as users(:manager)

    assert_difference -> { target.project_requirements.count }, 4 do
      post copy_project_requirements_path(target), params: { source_project_id: @tower.id }
    end

    assert_redirected_to edit_project_requirements_path(target)
    assert_equal "Copied 4 requirements from 2417 · Tower 2417 Upgrade (1 already here).", flash[:notice]

    assert_no_difference -> { ProjectRequirement.count } do
      post copy_project_requirements_path(target), params: { source_project_id: @tower.id }
    end
    assert_equal "Copied 0 requirements from 2417 · Tower 2417 Upgrade (5 already here).", flash[:notice]
  end

  test "copy needs another project" do
    sign_in_as users(:manager)

    [ @tower.id, "", Project.maximum(:id) + 1 ].each do |source_id|
      assert_no_difference -> { ProjectRequirement.count } do
        post copy_project_requirements_path(@tower), params: { source_project_id: source_id }
      end
      assert_redirected_to edit_project_requirements_path(@tower)
      assert_equal "Choose a project to copy from.", flash[:alert]
    end
  end

  test "edit for an unknown project is a 404" do
    sign_in_as users(:manager)

    get edit_project_requirements_path(project_id: Project.maximum(:id) + 1)

    assert_response :not_found
  end
end
