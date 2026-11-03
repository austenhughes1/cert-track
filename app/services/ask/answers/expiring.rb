module Ask
  module Answers
    # "What expires in the next 60 days?" Current certificates of active crew whose expiry
    # falls in the window (default: the next 30 days), soonest first. Narrowed by a person
    # (inactive allowed: they asked), a type, or a project ("on 2417": the certificates its
    # crew need there, from Compliance::ProjectReport).
    class Expiring < Base
      def call
        entries, total = project ? project_entries : certificate_entries
        items = entries.map { |certificate| item_for(certificate, project: project) }

        { status: :list, answer: join(summary(entries, total), person && inactive_note(person)), crew_member: person,
          crew_members: entries.map(&:crew_member).uniq, certificates: entries,
          sections: [ Section.new(key: :expiring, title: "Expiring", items: items, total: total) ] }
      end

      private
        def certificate_entries
          scope = Certificate.current.where(expires_on: window.range)
          scope = person ? scope.where(crew_member: person) : scope.joins(:crew_member).merge(CrewMember.active)
          scope = scope.where(certificate_type: certificate_type) if certificate_type
          entries = scope.preload(:crew_member, :certificate_type).order(:expires_on, :id).limit(LIST_LIMIT + 1).to_a
          total = entries.size > LIST_LIMIT ? scope.count : entries.size
          [ entries.first(LIST_LIMIT), total ]
        end

        def project_entries
          report = Compliance::ProjectReport.new(project, today: today)
          entries = report.rows.flat_map do |row|
            next [] if person && row.crew_member.id != person.id

            row.required_cells.filter_map do |cell|
              next unless cell.certificate && cell.expires_on && window.range.cover?(cell.expires_on)
              next if certificate_type && cell.certificate_type.id != certificate_type.id

              cell.certificate
            end
          end
          entries = entries.uniq(&:id).sort_by { |certificate| [ certificate.expires_on, certificate.id ] }
          [ entries.first(LIST_LIMIT), entries.size ]
        end

        def summary(entries, total)
          noun = certificate_type ? "#{certificate_type.name} certificate" : "certificate"
          filters = "#{" held by #{person.display_name}" if person}#{" on #{project.display_name}" if project}"
          return "No #{noun.pluralize}#{filters} expire #{window_text}." if total.zero?

          listed = entries.map { |certificate| entry_text(certificate) }
          listed += [ "#{total - entries.size} more" ] if total > entries.size
          "#{count(total, noun)}#{filters} #{total == 1 ? "expires" : "expire"} #{window_text}: #{sentence(listed)}."
        end

        def window_text
          window.label == "today" ? "today (#{date(window.to)})" : "#{window.label} (by #{date(window.to)})"
        end

        def entry_text(certificate)
          who = certificate.crew_member.display_name unless person
          what = certificate.certificate_type.name unless certificate_type
          subject = who && what ? "#{possessive(who)} #{what}" : (who || what)
          "#{subject} on #{date(certificate.expires_on)}"
        end
    end
  end
end
