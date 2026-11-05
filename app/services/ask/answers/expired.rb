module Ask
  module Answers
    # "Which certificates have expired?" Current certificates of active crew whose expiry has
    # already passed, most recently expired first. A past window ("last month", "recently",
    # "in the last 60 days") keeps only those that expired in it. Narrowed by a person
    # (inactive allowed: they asked), a type, or a project ("on 2417": the certificates its
    # crew need there, from Compliance::ProjectReport). One whose authenticity is flagged (confirmed
    # fake, or only flagged for review) says so.
    #   2 certificates have expired: Mari Garcia's First Aid/CPR/AED on Oct 29, 2026 and ...
    #   1 certificate expired in the last month (since Oct 3, 2026): Mari Garcia's ...
    class Expired < Base
      def call
        entries, total = project ? project_entries : certificate_entries
        items = entries.map { |certificate| item_for(certificate, project: project) }

        { status: :list, answer: join(summary(entries, total), person && inactive_note(person)), crew_member: person,
          crew_members: entries.map(&:crew_member).uniq, certificates: entries,
          sections: [ Section.new(key: :expired, title: "Expired", items: items, total: total) ] }
      end

      private
        # Before today, or within the past window the question named.
        def range
          window.past ? window.range : (...today)
        end

        def certificate_entries
          scope = Certificate.current.where(expires_on: range)
          scope = person ? scope.where(crew_member: person) : scope.joins(:crew_member).merge(CrewMember.active)
          scope = scope.where(certificate_type: certificate_type) if certificate_type
          entries = scope.preload(:crew_member, :certificate_type).order(expires_on: :desc, id: :desc).limit(LIST_LIMIT + 1).to_a
          total = entries.size > LIST_LIMIT ? scope.count : entries.size
          [ entries.first(LIST_LIMIT), total ]
        end

        def project_entries
          report = Compliance::ProjectReport.new(project, today: today)
          entries = report.rows.flat_map do |row|
            next [] if person && row.crew_member.id != person.id

            row.required_cells.filter_map do |cell|
              next unless cell.certificate && cell.expires_on && range.cover?(cell.expires_on)
              next if certificate_type && cell.certificate_type.id != certificate_type.id

              cell.certificate
            end
          end
          entries = entries.uniq(&:id).sort_by { |certificate| [ -certificate.expires_on.jd, -certificate.id ] }
          [ entries.first(LIST_LIMIT), entries.size ]
        end

        def summary(entries, total)
          noun = certificate_type ? "#{certificate_type.name} certificate" : "certificate"
          filters = "#{" held by #{person.display_name}" if person}#{" on #{project.display_name}" if project}"
          if total.zero?
            return "No #{noun.pluralize}#{filters} #{window.past ? "expired #{window_text}" : "have expired"}."
          end

          listed = entries.map { |certificate| entry_text(certificate) }
          listed += [ "#{total - entries.size} more" ] if total > entries.size
          verb = window.past ? "expired #{window_text}" : (total == 1 ? "has expired" : "have expired")
          "#{count(total, noun)}#{filters} #{verb}: #{sentence(listed)}."
        end

        def window_text
          window.label == "yesterday" ? "yesterday (#{date(window.to)})" : "#{window.label} (since #{date(window.from)})"
        end

        def entry_text(certificate)
          who = certificate.crew_member.display_name unless person
          what = certificate.certificate_type.name unless certificate_type
          subject = who && what ? "#{possessive(who)} #{what}" : (who || what)
          "#{subject} on #{date(certificate.expires_on)}#{authenticity_note(certificate)}"
        end
    end
  end
end
