require "test_helper"

class Projects::UpdateRequirementsTest < ActiveSupport::TestCase
  setup { @project = projects(:tower_2417) }

  def pairs_for(project)
    project.project_requirements.reload.map { |requirement| [ requirement.certificate_type_id, requirement.crew_role_id ] }.to_set
  end

  def current_pairs
    pairs_for(@project).to_a
  end

  test "key and parse round-trip everyone and role cells" do
    keys = [ Projects::UpdateRequirements.key(12, nil), Projects::UpdateRequirements.key(12, 3) ]

    assert_equal %w[12:everyone 12:3], keys
    assert_equal [ [ 12, nil ], [ 12, 3 ] ], Projects::UpdateRequirements.parse(keys)
  end

  test "parse ignores malformed and blank keys and removes duplicates" do
    parsed = Projects::UpdateRequirements.parse([ "", "abc", "1:", ":2", "1:2:3", "1;DROP", "5:everyone", "5:everyone", nil ])

    assert_equal [ [ 5, nil ] ], parsed
  end

  test "resubmitting the current grid changes nothing and keeps notes" do
    climber_requirement = project_requirements(:tower_climber_climbers)

    result = Projects::UpdateRequirements.new(@project, current_pairs).call

    assert_equal 0, result.added
    assert_equal 0, result.removed
    assert_not result.changed?
    assert_equal "Anyone working above 6 ft on the tower.", climber_requirement.reload.notes
  end

  test "adds everyone and role-specific rows and removes unchecked ones" do
    desired = current_pairs
    desired.delete([ certificate_types(:flagger).id, nil ])                    # untick Flagger for everyone
    desired.delete([ certificate_types(:cdl_a).id, crew_roles(:operator).id ]) # untick CDL for operators
    desired << [ certificate_types(:retired_hazwoper).id, nil ]                # Everyone
    desired << [ certificate_types(:cdl_a).id, crew_roles(:foreman).id ]       # one role
    desired << [ certificate_types(:climber).id, crew_roles(:foreman).id ]     # second role for an existing type

    result = Projects::UpdateRequirements.new(@project, desired).call

    assert_equal 3, result.added
    assert_equal 2, result.removed
    assert result.changed?
    assert_equal desired.to_set, pairs_for(@project)
    assert ProjectRequirement.exists?(project: @project, certificate_type: certificate_types(:retired_hazwoper), crew_role: nil)
    assert ProjectRequirement.exists?(project: @project, certificate_type: certificate_types(:climber), crew_role: crew_roles(:climber))
  end

  test "an everyone row and a role row for the same type can coexist" do
    desired = current_pairs + [ [ certificate_types(:climber).id, nil ] ]

    result = Projects::UpdateRequirements.new(@project, desired).call

    assert_equal 1, result.added
    assert_equal 2, @project.project_requirements.where(certificate_type: certificate_types(:climber)).count
  end

  test "an empty selection removes every requirement on the project only" do
    other_before = pairs_for(projects(:closed_2390))

    result = Projects::UpdateRequirements.new(@project, []).call

    assert_equal 5, result.removed
    assert_empty @project.project_requirements.reload
    assert_equal other_before, pairs_for(projects(:closed_2390))
  end

  test "drops selections for unknown types or roles" do
    missing_id = CertificateType.maximum(:id) + 1000
    missing_role_id = CrewRole.maximum(:id) + 1000
    desired = current_pairs + [ [ missing_id, nil ], [ certificate_types(:cdl_a).id, missing_role_id ] ]

    result = Projects::UpdateRequirements.new(@project, desired).call

    assert_equal 0, result.added
    assert_equal 0, result.removed
  end

  test "a pair added after the grid was built is kept, not duplicated" do
    pair = [ certificate_types(:retired_hazwoper).id, nil ]
    service = Projects::UpdateRequirements.new(@project, current_pairs + [ pair ])
    ProjectRequirement.create!(project: @project, certificate_type_id: pair.first)

    result = service.call

    assert_equal 0, result.added
    assert_equal 1, @project.project_requirements.where(certificate_type_id: pair.first).count
  end

  test "resets the project's loaded requirements" do
    @project.project_requirements.load

    Projects::UpdateRequirements.new(@project, []).call

    assert_not @project.project_requirements.loaded?
    assert_empty @project.project_requirements
  end
end
