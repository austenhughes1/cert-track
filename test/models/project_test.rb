require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "requires a name and a unique code" do
    assert_not Project.new(name: " ").valid?
    duplicate = Project.new(name: "Other", code: " 2417 ")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:code], "has already been taken"
    assert Project.new(name: "No code", code: " ").valid?
  end

  test "ends_on cannot precede starts_on" do
    project = Project.new(name: "P", starts_on: Date.new(2026, 5, 1), ends_on: Date.new(2026, 4, 30))
    assert_not project.valid?
    assert_includes project.errors[:ends_on], "can't be before the start date"
  end

  test "status enum defaults to active" do
    assert Project.new.active?
    assert_equal [ projects(:tower_2417) ], Project.active.to_a
    assert_equal [ projects(:closed_2390) ], Project.closed.to_a
    assert_includes Project.not_closed, projects(:tower_2417)
    assert_not Project.new(name: "P", status: "bogus").valid?
  end

  test "display_name" do
    assert_equal "2417 · Tower 2417 Upgrade", projects(:tower_2417).display_name
    assert_equal "Plain", Project.new(name: "Plain").display_name
  end

  test "requirements_for returns everyone's plus the role's requirements" do
    project = projects(:tower_2417)
    everyone = %w[FIRSTAID FLAGGER OSHA30]
    assert_equal everyone, project.requirements_for(nil).map { _1.certificate_type.code }.sort
    assert_equal (everyone + [ "CLIMBER" ]).sort, project.requirements_for(crew_roles(:climber)).map { _1.certificate_type.code }.sort
    assert_equal (everyone + [ "CDLA" ]).sort, project.requirements_for(crew_roles(:operator).id).map { _1.certificate_type.code }.sort
  end

  test "requirements_for uses preloaded requirements" do
    project = Project.includes(project_requirements: :certificate_type).find(projects(:tower_2417).id)
    climber = crew_roles(:climber)
    assert_queries_count(0) { assert_equal 4, project.requirements_for(climber).size }
  end

  test "required_certificate_types is distinct" do
    assert_equal 5, projects(:tower_2417).required_certificate_types.count
  end

  test "copy_requirements_from! adds missing requirements only" do
    target = Project.create!(name: "New site")
    target.project_requirements.create!(certificate_type: certificate_types(:osha30))
    assert_equal 4, target.copy_requirements_from!(projects(:tower_2417))
    assert_equal 5, target.project_requirements.count
    assert_equal 0, target.copy_requirements_from!(projects(:tower_2417))
  end

  test "destroying a project removes its requirements and assignments" do
    project = projects(:tower_2417)
    assert project.destroy
    assert_equal 0, ProjectRequirement.where(project_id: project.id).count
    assert_equal 0, ProjectAssignment.where(project_id: project.id).count
  end

  test "has a packet attachment" do
    project = projects(:tower_2417)
    project.packet.attach(io: StringIO.new("zip"), filename: "packet.zip", content_type: "application/zip")
    assert project.packet.attached?
  end
end
