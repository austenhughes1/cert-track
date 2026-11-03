module Notifications
  # Builds DigestItems from current certificates of active crew members that have an expiry
  # date. Ignores the send log; Notifications::ExpiryScan filters what each recipient already got.
  # Query count is fixed (certificates, members, types, assignments, projects, requirements) at any size.
  class DigestBuilder
    DAILY_WINDOW = ExpiryNotification::THRESHOLD_DAYS.values.max # 90: the d90 threshold
    WEEKLY_WINDOW = Compliance::EXPIRING_WINDOW # 30

    # Everything that has crossed a threshold today: expires within 90 days, or already expired.
    def self.daily_items(today: Date.current)
      new(today: today).items_expiring_within(DAILY_WINDOW)
    end

    # The Monday list: everything expiring within 30 days, expired certificates included.
    def self.weekly_items(today: Date.current)
      new(today: today).items_expiring_within(WEEKLY_WINDOW)
    end

    attr_reader :today

    def initialize(today: Date.current)
      @today = today
    end

    # DigestItems ordered by expiry date (soonest first), then person and type.
    def items_expiring_within(days)
      certificates = candidates.where(expires_on: ..(today + days)).to_a
      projects = active_projects_by_member_and_type(certificates.map(&:crew_member).uniq)

      certificates.map { |certificate| item_for(certificate, projects) }
        .sort_by { |item| [ item.expires_on, item.crew_member.sort_name, item.certificate_type.name, item.certificate.id ] }
    end

    private
      def candidates
        Certificate.current.where.not(expires_on: nil)
          .joins(:crew_member).merge(CrewMember.active)
          .preload(:crew_member, :certificate_type)
      end

      def item_for(certificate, projects)
        days_left = (certificate.expires_on - today).to_i

        DigestItem.new(
          certificate: certificate,
          crew_member: certificate.crew_member,
          certificate_type: certificate.certificate_type,
          threshold: Threshold.for_days_left(days_left),
          expires_on: certificate.expires_on,
          days_left: days_left,
          projects: projects.fetch([ certificate.crew_member_id, certificate.certificate_type_id ], [])
        )
      end

      # {[crew_member_id, certificate_type_id] => [Project, ...]}: active projects where the
      # person is still on the crew (ProjectAssignment.on_crew) and a requirement for that type
      # applies to their effective role. Reuses the already-loaded crew members for the role
      # fallback instead of loading them again.
      def active_projects_by_member_and_type(crew_members)
        return {} if crew_members.empty?

        members_by_id = crew_members.index_by(&:id)
        assignments = ProjectAssignment.on_crew(today: today).merge(Project.active)
          .where(crew_member_id: members_by_id.keys)
          .preload(project: :project_requirements)

        index = Hash.new { |hash, key| hash[key] = [] }
        assignments.each do |assignment|
          role_id = assignment.crew_role_id || members_by_id.fetch(assignment.crew_member_id).crew_role_id
          assignment.project.requirements_for(role_id).each do |requirement|
            index[[ assignment.crew_member_id, requirement.certificate_type_id ]] << assignment.project
          end
        end
        index.transform_values { |projects| projects.uniq.sort_by { |project| [ project.name, project.id ] } }
      end
  end
end
