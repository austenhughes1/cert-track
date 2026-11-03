module Compliance
  class ProjectReport
    # Loads everything the reports for a set of projects need in four queries:
    #   1. requirements with their types (the columns)
    #   2. the cell query: assignments of active members joined to the requirements
    #      that apply to their effective role and to their current certificate per type
    #   3. those assignments with members and both roles (the rows)
    #   4. the current certificates found by query 2 (skipped when there are none)
    # Only assignments still on the crew count (ProjectAssignment.on_crew): on an open
    # project, someone whose assignment ended is neither a row nor a gap.
    class Dataset
      CELL_JOINS = <<~SQL.squish.freeze
        INNER JOIN crew_members ON crew_members.id = project_assignments.crew_member_id
        INNER JOIN project_requirements
          ON project_requirements.project_id = project_assignments.project_id
          AND (project_requirements.crew_role_id IS NULL
            OR project_requirements.crew_role_id = COALESCE(project_assignments.crew_role_id, crew_members.crew_role_id))
        LEFT JOIN certificates
          ON certificates.crew_member_id = project_assignments.crew_member_id
          AND certificates.certificate_type_id = project_requirements.certificate_type_id
          AND certificates.superseded_at IS NULL
      SQL

      def initialize(projects, today: Date.current)
        @project_ids = projects.map(&:id).uniq
        @today = today
      end

      def columns_for(project_id)
        columns_by_project.fetch(project_id, [])
      end

      def assignments_for(project_id)
        assignments_by_project.fetch(project_id, [])
      end

      # Hash{certificate_type_id => current certificate id or nil} for the types this
      # assignment's person needs.
      def required_certificate_ids_for(assignment_id)
        required_cells.fetch(assignment_id, {})
      end

      def certificate(id)
        certificates_by_id[id] if id
      end

      private
        def columns_by_project
          @columns_by_project ||= begin
            types = {}
            requirements = ProjectRequirement.where(project_id: @project_ids).eager_load(:certificate_type)
              .order(CertificateType.arel_table[:position].asc.nulls_last, CertificateType.arel_table[:name].asc,
                CertificateType.arel_table[:id].asc)

            requirements.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |requirement, columns|
              type = types[requirement.certificate_type_id] ||= requirement.certificate_type
              columns[requirement.project_id] << type unless columns[requirement.project_id].include?(type)
            end
          end
        end

        def required_cells
          @required_cells ||= begin
            rows = crew_assignments.joins(CELL_JOINS).where(crew_members: { active: true })
              .distinct.pluck("project_assignments.id", "project_requirements.certificate_type_id", "certificates.id")

            rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |(assignment_id, type_id, certificate_id), cells|
              cells[assignment_id][type_id] = certificate_id
            end
          end
        end

        def assignments_by_project
          @assignments_by_project ||= crew_assignments
            .eager_load(:crew_role, crew_member: :crew_role).where(crew_members: { active: true })
            .order("crew_members.last_name", "crew_members.first_name", "crew_members.id", "project_assignments.id")
            .group_by(&:project_id)
        end

        def crew_assignments
          ProjectAssignment.where(project_id: @project_ids).on_crew(today: @today)
        end

        def certificates_by_id
          @certificates_by_id ||= begin
            ids = required_cells.values.flat_map(&:values).compact.uniq
            ids.empty? ? {} : Certificate.where(id: ids).index_by(&:id)
          end
        end
    end
  end
end
