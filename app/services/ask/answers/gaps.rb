module Ask
  module Answers
    # "What's missing on 2417?" Missing, expired and confirmed fake requirements
    # (Compliance::ProjectReport#gaps) on one project, or on every active project
    # (Compliance::Overview) when none is named. Narrowed by a person or a type. One
    # section per project. A certificate only flagged for review is a gap only if its dates make it one.
    #   2417 · Tower 2417 Upgrade has 3 gaps (1 confirmed fake, 1 expired, 1 missing): Juan Ortiz: Flagger
    #   (confirmed fake: not found by issuer); Mari Garcia: Flagger (missing), First Aid/CPR/AED (expired ...).
    class Gaps < Base
      def call
        reports = project ? [ Compliance::ProjectReport.new(project, today: today) ] : Compliance::Overview.new(Project.active.ordered, today: today).reports
        gaps = reports.flat_map(&:gaps).select { |gap| wanted?(gap) }
        groups = gaps.group_by { |gap| gap.project.id }

        sections = reports.filter_map do |report|
          project_gaps = groups[report.project.id]
          next unless project_gaps

          items = project_gaps.map do |gap|
            Item.new(crew_member: gap.crew_member, certificate_type: gap.certificate_type, certificate: gap.certificate,
              status: gap.status, project: gap.project)
          end
          section(:"project_#{report.project.id}", items, title: report.project.display_name)
        end

        { status: :list, answer: join(summary(reports, gaps, groups), *notes), crew_member: person,
          crew_members: gaps.map(&:crew_member).uniq, certificates: gaps.filter_map(&:certificate), sections: sections }
      end

      private
        def wanted?(gap)
          (person.nil? || gap.crew_member.id == person.id) && (certificate_type.nil? || gap.certificate_type.id == certificate_type.id)
        end

        def summary(reports, gaps, groups)
          return none_text(reports) if gaps.empty?

          noun = certificate_type ? "#{certificate_type.name} gap" : "gap"
          tally = "#{count(gaps.size, noun)} (#{breakdown(gaps)})"
          if project
            subject = person ? person.display_name : project.display_name
            on = person ? " on #{project.display_name}" : ""
            "#{subject} has #{tally}#{on}: #{details(gaps)}."
          else
            on_projects = "on #{count(groups.size, "active project")}"
            lead = person ? "#{person.display_name} has #{tally} #{on_projects}." : "#{count(gaps.size, noun)} #{on_projects} (#{breakdown(gaps)})."
            per_project = groups.values.map { |project_gaps| "#{project_gaps.first.project.display_name}: #{details(project_gaps)}." }
            join(lead, *per_project)
          end
        end

        # "1 confirmed fake, 2 expired, 3 missing"
        def breakdown(gaps)
          gaps.group_by(&:status).sort_by { |status, _| Compliance::SEVERITY.index(status) }
            .map { |status, status_gaps| "#{status_gaps.size} #{Compliance.label(status).downcase}" }.join(", ")
        end

        # "Mari Garcia: Flagger (missing), First Aid/CPR/AED (expired Oct 29, 2026); Li Chen: ..."
        # The person's name is left out when the question named them; the type when it named one.
        def details(gaps)
          gaps.group_by { |gap| gap.crew_member.id }.values.map do |member_gaps|
            parts = member_gaps.map { |gap| gap_text(gap) }
            name = member_gaps.first.crew_member.display_name
            if person then sentence(parts)
            elsif certificate_type then "#{name} (#{parts.join(", ")})"
            else "#{name}: #{parts.join(", ")}"
            end
          end.join("; ")
        end

        def gap_text(gap)
          state = gap_state(gap)
          certificate_type ? state : "#{gap.certificate_type.name} (#{state})"
        end

        def none_text(reports)
          type_text = certificate_type ? "#{certificate_type.name} " : ""
          if project
            if person && reports.first.row_for(person).nil?
              "#{person.display_name} isn't on the crew of #{project.display_name}."
            elsif person
              "#{person.display_name} has no #{type_text}gaps on #{project.display_name}."
            else
              "No #{type_text}gaps on #{project.display_name}: everyone on the crew holds a current certificate for each type they need."
            end
          elsif reports.empty?
            "There are no active projects to check."
          elsif person
            "#{person.display_name} has no #{type_text}gaps on active projects."
          else
            "No #{type_text}gaps on active projects: everyone on each crew holds a current certificate for each type they need."
          end
        end

        def notes
          [
            ("#{person.display_name} is marked inactive, so they aren't checked against project requirements." if person && !person.active?),
            ("#{project.display_name} is #{project.status}." if project && !project.active?)
          ]
        end
    end
  end
end
