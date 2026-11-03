require "test_helper"

class ProjectAssignmentTest < ActiveSupport::TestCase
  test "a member is assigned once per project" do
    duplicate = ProjectAssignment.new(project: projects(:tower_2417), crew_member: crew_members(:juan_ortiz))
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:crew_member_id], "is already assigned to this project"
  end

  test "ends_on cannot precede starts_on" do
    assignment = ProjectAssignment.new(project: projects(:closed_2390), crew_member: crew_members(:li_chen),
      starts_on: Date.new(2026, 5, 2), ends_on: Date.new(2026, 5, 1))
    assert_not assignment.valid?
  end

  test "on_crew leaves out assignments that ended before today" do
    today = Date.current
    tower = projects(:tower_2417)
    member = ->(name) { CrewMember.create!(first_name: name, last_name: "Crew") }
    ended = tower.project_assignments.create!(crew_member: member.("Ended"), starts_on: today - 40, ends_on: today - 1)
    last_day = tower.project_assignments.create!(crew_member: member.("Last"), ends_on: today)
    upcoming = tower.project_assignments.create!(crew_member: member.("Upcoming"), starts_on: today + 14)

    on_crew = ProjectAssignment.on_crew(today: today)
    assert_not_includes on_crew, ended
    assert_includes on_crew, last_day
    assert_includes on_crew, upcoming
    assert_includes on_crew, project_assignments(:tower_dave) # no dates
    assert_includes ProjectAssignment.on_crew(today: today - 1), ended
  end

  test "on_crew applies to a project running past its planned end" do
    overrun = Project.create!(name: "Overrun", status: :active, starts_on: Date.current - 90, ends_on: Date.current - 10)
    left = overrun.project_assignments.create!(crew_member: crew_members(:li_chen), ends_on: Date.current - 5)
    staying = overrun.project_assignments.create!(crew_member: crew_members(:juan_ortiz))

    assert_equal [ staying ], ProjectAssignment.on_crew.where(project: overrun).to_a
    assert_not_includes ProjectAssignment.on_crew, left
  end

  test "on_crew keeps every assignment on a closed project" do
    closed = projects(:closed_2390) # closed_juan ended 200 days ago
    left_early = closed.project_assignments.create!(crew_member: crew_members(:li_chen), ends_on: closed.ends_on - 30)

    assert_equal [ project_assignments(:closed_juan), project_assignments(:closed_sam), left_early ].sort,
      ProjectAssignment.on_crew.where(project: closed).sort
  end

  test "effective_role prefers the assignment role" do
    assert_equal crew_roles(:climber), project_assignments(:tower_li_chen).effective_role
    assert_equal crew_roles(:operator), project_assignments(:tower_dave).effective_role
    assert_equal crew_roles(:climber).id, project_assignments(:tower_juan).effective_role_id
  end

  test "effective_role is nil when neither has a role" do
    member = CrewMember.create!(first_name: "No", last_name: "Role")
    assert_nil ProjectAssignment.new(project: projects(:tower_2417), crew_member: member).effective_role
  end

  test "required_certificate_types follows the effective role" do
    codes = ->(name) { project_assignments(name).required_certificate_types.map(&:code).sort }
    assert_equal %w[CLIMBER FIRSTAID FLAGGER OSHA30], codes.(:tower_li_chen)
    assert_equal %w[CDLA FIRSTAID FLAGGER OSHA30], codes.(:tower_dave)
    assert_equal %w[FIRSTAID FLAGGER OSHA30], codes.(:tower_maria)
  end
end
