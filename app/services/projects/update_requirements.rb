# Applies the requirements editor's checkbox grid to a project. Each selection is a
# [certificate_type_id, crew_role_id] pair, where crew_role_id nil means "everyone".
# Missing pairs are inserted and unselected rows deleted, in one transaction with the
# project row locked; rows that stay selected (and their notes) are left alone.
#
#   pairs  = Projects::UpdateRequirements.parse(params[:requirement_keys])
#   result = Projects::UpdateRequirements.new(project, pairs).call
#   result.added   # => 2
#   result.removed # => 1
module Projects
  class UpdateRequirements
    EVERYONE = "everyone"
    KEY_FORMAT = /\A(\d+):(#{EVERYONE}|\d+)\z/

    Result = Data.define(:added, :removed) do
      def changed? = added.positive? || removed.positive?
    end

    class << self
      # Checkbox value for one grid cell: "12:everyone" or "12:3".
      def key(certificate_type_id, crew_role_id)
        "#{certificate_type_id}:#{crew_role_id || EVERYONE}"
      end

      # ["12:everyone", "12:3"] -> [[12, nil], [12, 3]]. Malformed keys are ignored.
      def parse(keys)
        Array(keys).filter_map do |key|
          next unless (match = KEY_FORMAT.match(key.to_s))

          [ match[1].to_i, match[2] == EVERYONE ? nil : match[2].to_i ]
        end.uniq
      end
    end

    def initialize(project, selections)
      @project = project
      @selections = selections.map { |type_id, role_id| [ Integer(type_id), role_id && Integer(role_id) ] }.uniq
    end

    def call
      desired = valid_selections
      added = removed = 0

      project.with_lock do
        existing = project.project_requirements.pluck(:id, :certificate_type_id, :crew_role_id)
        existing_pairs = existing.map { |_id, type_id, role_id| [ type_id, role_id ] }

        stale_ids = existing.filter_map { |id, type_id, role_id| id unless desired.include?([ type_id, role_id ]) }
        removed = project.project_requirements.where(id: stale_ids).delete_all if stale_ids.any?

        rows = (desired - existing_pairs).map do |type_id, role_id|
          { project_id: project.id, certificate_type_id: type_id, crew_role_id: role_id }
        end
        # ON CONFLICT DO NOTHING: the unique index (NULLS NOT DISTINCT) absorbs any race.
        added = ProjectRequirement.insert_all(rows, returning: :id).length if rows.any?
      end

      project.project_requirements.reset
      Result.new(added:, removed:)
    end

    private
      attr_reader :project, :selections

      # Drops pairs that point at certificate types or crew roles that don't exist.
      def valid_selections
        type_ids = CertificateType.where(id: selections.map(&:first)).pluck(:id).to_set
        role_ids = CrewRole.where(id: selections.filter_map(&:last)).pluck(:id).to_set

        selections.select { |type_id, role_id| type_ids.include?(type_id) && (role_id.nil? || role_ids.include?(role_id)) }
      end
  end
end
