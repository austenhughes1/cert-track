module Ask
  module Answers
    # "Who has Flagger?" Everyone whose current certificate of the type hasn't expired and isn't
    # confirmed fake, with its status; one only flagged for review still counts and says so.
    # Confirmed fake ones, expired ones and inactive crew are listed separately. "on 2417"
    # narrows it to that project's crew.
    #   2 people hold a current Flagger certificate: Li Chen (expires Mar 18, 2028) and Juan Ortiz (expires
    #   in 12 days, Nov 16, 2026; flagged for review: not found by issuer). Confirmed fake, so not counted:
    #   Dave Miller (doesn't match issuer).
    class Holders < Base
      def call
        certificates = scope.to_a
        certificates.each { |certificate| certificate.association(:certificate_type).target = certificate_type }
        groups = certificates.group_by do |certificate|
          next :inactive unless certificate.crew_member.active?

          case Compliance.status_for(certificate, today: today)
          when "fake" then :fake
          when "expired" then :expired
          else :current
          end
        end
        current, fake, expired, inactive = groups.values_at(:current, :fake, :expired, :inactive).map { |group| group || [] }

        sections = [
          (section(:current, current.map { |certificate| item_for(certificate) }, title: "Current") if current.any?),
          (section(:fake, fake.map { |certificate| item_for(certificate) }, title: "Confirmed fake") if fake.any?),
          (section(:expired, expired.map { |certificate| item_for(certificate) }, title: "Expired") if expired.any?),
          (section(:inactive, inactive.map { |certificate| item_for(certificate) }, title: "Inactive crew") if inactive.any?)
        ].compact

        { status: :list,
          answer: join(current_sentence(current), fake_sentence(fake), expired_sentence(expired), inactive_sentence(inactive)),
          crew_members: current.map(&:crew_member), certificates: certificates, sections: sections }
      end

      private
        def scope
          certificates = Certificate.current.where(certificate_type: certificate_type).eager_load(:crew_member)
            .order("crew_members.last_name", "crew_members.first_name", "crew_members.id")
          return certificates unless project

          certificates.where(crew_member_id: ProjectAssignment.where(project: project).on_crew(today: today).select(:crew_member_id))
        end

        def where_text
          project ? " on #{project.display_name}" : ""
        end

        def current_sentence(current)
          return "Nobody#{where_text} holds a current #{certificate_type.name} certificate." if current.empty?

          names = current.map do |certificate|
            "#{certificate.crew_member.display_name} (#{with_authenticity(expiry(certificate.expires_on, today: today), certificate)})"
          end
          "#{count(current.size, "person", "people")}#{where_text} #{current.one? ? "holds" : "hold"} a current " \
            "#{certificate_type.name} certificate: #{sentence(names)}."
        end

        # "Confirmed fake, so not counted: Li Chen (not found by issuer)."
        def fake_sentence(fake)
          return if fake.empty?

          names = fake.map { |certificate| "#{certificate.crew_member.display_name} (#{certificate.authenticity_label.downcase})" }
          "Confirmed fake, so not counted: #{sentence(names)}."
        end

        def expired_sentence(expired)
          return if expired.empty?

          names = expired.map { |certificate| "#{certificate.crew_member.display_name} (#{with_authenticity(date(certificate.expires_on), certificate)})" }
          "Expired: #{sentence(names)}."
        end

        def inactive_sentence(inactive)
          return if inactive.empty?

          "Also on file for inactive crew: #{sentence(inactive.map { |certificate| certificate.crew_member.display_name })}."
        end
    end
  end
end
