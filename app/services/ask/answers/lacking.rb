module Ask
  module Answers
    # "Who doesn't have Flagger?" Active crew without a current, unexpired certificate of the
    # type (nothing on file, the last one expired, or it is confirmed fake), whether or not a
    # project requires it (that is Answers::Gaps). One only flagged for review still counts, so
    # its holder isn't listed. "on 2417" narrows it to that project's crew.
    #   2 active crew members don't hold a current Flagger certificate: Mari Garcia (none on file) and
    #   Juan Ortiz (confirmed fake: not found by issuer).
    #   Everyone on the active crew holds a current Flagger certificate.
    class Lacking < Base
      HOLDING = %w[valid expiring lapses_on_project].freeze

      def call
        members = crew.to_a
        held = Certificate.current.where(certificate_type: certificate_type, crew_member_id: members.map(&:id)).index_by(&:crew_member_id)
        items = members.filter_map do |member|
          certificate = held[member.id]
          status = Compliance.status_for(certificate, today: today)
          next if HOLDING.include?(status)

          if certificate
            certificate.association(:crew_member).target = member
            certificate.association(:certificate_type).target = certificate_type
          end
          Item.new(crew_member: member, certificate_type: certificate_type, certificate: certificate, status: status, project: project)
        end

        { status: :list, answer: summary(members, items), crew_members: items.map(&:crew_member),
          certificates: items.filter_map(&:certificate),
          sections: [ section(:lacking, items, title: "No current #{certificate_type.name}") ] }
      end

      private
        def crew
          scope = CrewMember.active.ordered
          project ? scope.where(id: ProjectAssignment.where(project: project).on_crew(today: today).select(:crew_member_id)) : scope
        end

        def summary(members, items)
          type = certificate_type.name
          if members.empty?
            project ? "Nobody active is on the crew of #{project.display_name}." : "There is no active crew to check."
          elsif items.empty?
            "Everyone #{project ? "on #{project.display_name}" : "on the active crew"} holds a current #{type} certificate."
          else
            who = project ? "#{count(items.size, "person", "people")} on #{project.display_name}" : count(items.size, "active crew member")
            "#{who} #{items.one? ? "doesn't" : "don't"} hold a current #{type} certificate: #{sentence(items.map { |item| item_text(item) })}."
          end
        end

        def item_text(item)
          state = case item.status
          when "fake" then confirmed_fake(item.certificate)
          when "expired" then with_authenticity("expired #{date(item.certificate.expires_on)}", item.certificate)
          else "none on file"
          end
          "#{item.crew_member.display_name} (#{state})"
        end
    end
  end
end
