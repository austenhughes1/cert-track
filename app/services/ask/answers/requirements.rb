module Ask
  module Answers
    # "What's required on 2417?" The certificate types a project requires, with the role
    # when a requirement is for one role only, then one sentence on how the crew measures
    # up (Compliance::ProjectReport). A type narrows it to that requirement ("Is flagger
    # required on 2417?"). Evidence: the requirements, then the crew's gaps.
    #   2417 · Tower 2417 Upgrade requires 5 certificate types: OSHA 30 Construction, Flagger,
    #   First Aid/CPR/AED, Authorized Climber (Climber role), and CDL Class A (Operator role).
    #   3 of 4 assigned crew are missing at least one: Li Chen, Mari Garcia, and Dave Miller.
    class Requirements < Base
      def call
        report = Compliance::ProjectReport.new(project, today: today)
        requirements = requirements_for(report)
        gaps = requirements.any? ? report.gaps.select { |gap| certificate_type.nil? || gap.certificate_type.id == certificate_type.id } : []
        items = gaps.map do |gap|
          Item.new(crew_member: gap.crew_member, certificate_type: gap.certificate_type, certificate: gap.certificate,
            status: gap.status, project: project)
        end

        sections = [
          (Section.new(key: :requirements, title: "Requirements", items: requirements) if requirements.any?),
          (section(:gaps, items, title: "Missing or expired") if items.any?)
        ].compact
        { status: :list, answer: join(requirements_sentence(requirements), crew_sentence(report, requirements, gaps), project_note),
          crew_members: gaps.map(&:crew_member).uniq, certificates: gaps.filter_map(&:certificate), sections: sections }
      end

      private
        # One Requirement per type, in master-list order. A type required of everyone and
        # of a role is required of everyone.
        def requirements_for(report)
          records = project.project_requirements.eager_load(:certificate_type, :crew_role).to_a
          records.select! { |record| record.certificate_type_id == certificate_type.id } if certificate_type

          records.group_by(&:certificate_type).sort_by { |type, _| type_order(type) }.map do |type, type_records|
            roles = type_records.any?(&:everyone?) ? [] : type_records.map(&:crew_role).uniq.sort_by(&:name)
            cells = report.rows.filter_map { |row| row.cell_for(type) }.select(&:required?)
            Requirement.new(certificate_type: type, crew_roles: roles, notes: type_records.filter_map(&:notes).uniq,
              needed: cells.size, missing: cells.count(&:gap?))
          end
        end

        def requirements_sentence(requirements)
          name = project.display_name
          if requirements.empty?
            certificate_type ? "#{name} doesn't require #{certificate_type.name}." : "#{name} has no certificate requirements yet."
          elsif certificate_type
            requirement = requirements.sole
            who = requirement.everyone? ? "everyone on the crew" : "the #{role_names(requirement)}"
            "#{name} requires #{certificate_type.name} for #{who}."
          else
            listed = requirements.map do |requirement|
              requirement.everyone? ? requirement.certificate_type.name : "#{requirement.certificate_type.name} (#{role_names(requirement)})"
            end
            "#{name} requires #{count(requirements.size, "certificate type")}: #{sentence(listed)}."
          end
        end

        # "Climber role", "Climber and Operator roles"
        def role_names(requirement)
          names = requirement.crew_roles.map(&:name)
          "#{names.to_sentence} #{names.one? ? "role" : "roles"}"
        end

        # How the people on the crew measure up against the requirements listed.
        def crew_sentence(report, requirements, gaps)
          return if requirements.empty?

          crew = report.rows.map(&:crew_member).uniq
          return "Nobody is on the crew." if crew.empty?

          short = gaps.map(&:crew_member).uniq
          if certificate_type
            needed = requirements.sole.needed
            if needed.zero? then "Nobody on the crew needs it."
            elsif short.empty? then "Everyone on the crew who needs it (#{count(needed, "person", "people")}) holds a current one."
            else "#{short.size} of #{needed} on the crew who need it #{short.one? ? "is" : "are"} missing it: #{sentence(gaps.map { |gap| gap_text(gap) })}."
            end
          elsif short.empty?
            "Everyone on the crew (#{count(crew.size, "person", "people")}) holds a current certificate for each type they need."
          else
            "#{short.size} of #{crew.size} assigned crew #{short.one? ? "is" : "are"} missing at least one: " \
              "#{sentence(short.map(&:display_name))}."
          end
        end

        # "Mari Garcia (missing)", "Li Chen (expired Sep 29, 2025)"
        def gap_text(gap)
          state = gap.status == "expired" ? "expired #{date(gap.certificate.expires_on)}" : "missing"
          "#{gap.crew_member.display_name} (#{state})"
        end

        def project_note
          "#{project.display_name} is #{project.status}." unless project.active?
        end
    end
  end
end
