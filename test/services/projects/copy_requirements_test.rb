require "test_helper"

class Projects::CopyRequirementsTest < ActiveSupport::TestCase
  setup do
    @source = projects(:tower_2417)
    @target = Project.create!(name: "Tower 2420", code: "2420", status: :planned)
  end

  def pairs_for(project)
    project.project_requirements.reload.map { |requirement| [ requirement.certificate_type_id, requirement.crew_role_id ] }.to_set
  end

  test "copies every requirement, role limits and notes into an empty project" do
    result = Projects::CopyRequirements.new(@target, @source).call

    assert_equal 5, result.added
    assert_equal 0, result.already_present
    assert_equal 0, result.skipped_inactive
    assert_equal pairs_for(@source), pairs_for(@target)
    copied = @target.project_requirements.find_by!(certificate_type: certificate_types(:climber))
    assert_equal crew_roles(:climber), copied.crew_role
    assert_equal "Anyone working above 6 ft on the tower.", copied.notes
  end

  test "merges without duplicating pairs the target already has" do
    @target.project_requirements.create!(certificate_type: certificate_types(:osha30))
    @target.project_requirements.create!(certificate_type: certificate_types(:climber), crew_role: crew_roles(:climber), notes: "Keep me")
    @target.project_requirements.create!(certificate_type: certificate_types(:climber)) # everyone; source has climber-only

    result = Projects::CopyRequirements.new(@target, @source).call

    assert_equal 3, result.added
    assert_equal 2, result.already_present
    assert_equal pairs_for(@source) + [ [ certificate_types(:climber).id, nil ] ], pairs_for(@target)
    assert_equal "Keep me", @target.project_requirements.find_by!(crew_role: crew_roles(:climber)).notes
  end

  test "copying twice adds nothing the second time" do
    Projects::CopyRequirements.new(@target, @source).call

    assert_no_difference -> { ProjectRequirement.count } do
      result = Projects::CopyRequirements.new(@target, @source).call
      assert_equal 0, result.added
      assert_equal 5, result.already_present
    end
  end

  test "skips requirements on retired certificate types" do
    @source.project_requirements.create!(certificate_type: certificate_types(:retired_hazwoper))

    result = Projects::CopyRequirements.new(@target, @source).call

    assert_equal 5, result.added
    assert_equal 1, result.skipped_inactive
    assert_not @target.project_requirements.exists?(certificate_type: certificate_types(:retired_hazwoper))
  end

  test "leaves the source project untouched" do
    before = pairs_for(@source)

    Projects::CopyRequirements.new(@target, @source).call

    assert_equal before, pairs_for(@source)
  end

  test "refuses to copy a project onto itself" do
    assert_raises(ArgumentError) { Projects::CopyRequirements.new(@source, Project.find(@source.id)) }
  end
end
