require "test_helper"

class ProjectRequirementTest < ActiveSupport::TestCase
  test "a type is required once per project and role" do
    duplicate = ProjectRequirement.new(project: projects(:tower_2417), certificate_type: certificate_types(:osha30))
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:certificate_type_id], "is already required for that role"

    assert ProjectRequirement.new(project: projects(:tower_2417), certificate_type: certificate_types(:osha30),
      crew_role: crew_roles(:foreman)).valid?
  end

  test "the database treats a null role as a value" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      ProjectRequirement.insert_all!([ { project_id: projects(:tower_2417).id, certificate_type_id: certificate_types(:osha30).id } ])
    end
  end

  test "for_role and applies_to?" do
    climber = crew_roles(:climber)
    codes = projects(:tower_2417).project_requirements.for_role(climber).map { _1.certificate_type.code }
    assert_equal %w[CLIMBER FIRSTAID FLAGGER OSHA30], codes.sort
    assert_equal 3, projects(:tower_2417).project_requirements.for_everyone.count
    assert project_requirements(:tower_osha30).everyone?
    assert project_requirements(:tower_climber_climbers).applies_to?(climber.id)
    assert_not project_requirements(:tower_climber_climbers).applies_to?(crew_roles(:operator).id)
    assert_not project_requirements(:tower_climber_climbers).applies_to?(nil)
  end
end
