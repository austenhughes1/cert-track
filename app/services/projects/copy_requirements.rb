# Merges another project's requirements into a project ("copy requirements from").
# Pairs the target already has are skipped, as are requirements on retired (inactive)
# certificate types. Notes are copied with each new row.
#
#   result = Projects::CopyRequirements.new(project, source).call
#   result.added            # => 3
#   result.already_present  # => 2
#   result.skipped_inactive # => 0
module Projects
  class CopyRequirements
    Result = Data.define(:added, :already_present, :skipped_inactive)

    def initialize(project, source)
      raise ArgumentError, "can't copy a project's requirements onto itself" if project.id == source.id

      @project = project
      @source = source
    end

    def call
      candidates = source.project_requirements.includes(:certificate_type).to_a
      active, inactive = candidates.partition { |requirement| requirement.certificate_type.active? }
      added = 0

      project.with_lock do
        existing = project.project_requirements.pluck(:certificate_type_id, :crew_role_id).to_set
        rows = active.reject { |requirement| existing.include?([ requirement.certificate_type_id, requirement.crew_role_id ]) }
          .map do |requirement|
            { project_id: project.id, certificate_type_id: requirement.certificate_type_id,
              crew_role_id: requirement.crew_role_id, notes: requirement.notes }
          end
        # ON CONFLICT DO NOTHING, so a concurrent save can't make this raise.
        added = ProjectRequirement.insert_all(rows, returning: :id).length if rows.any?
      end

      project.project_requirements.reset
      Result.new(added:, already_present: active.size - added, skipped_inactive: inactive.size)
    end

    private
      attr_reader :project, :source
  end
end
