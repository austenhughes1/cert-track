module Ask
  module Answers
    # "Who has Flagger?" Everyone whose current certificate of the type hasn't expired,
    # with its status; expired ones and inactive crew are listed separately. "on 2417"
    # narrows it to that project's crew.
    class Holders < Base
      def call
        certificates = scope.to_a
        certificates.each { |certificate| certificate.association(:certificate_type).target = certificate_type }
        groups = certificates.group_by do |certificate|
          if !certificate.crew_member.active? then :inactive
          elsif Compliance.status_for(certificate, today: today) == "expired" then :expired
          else :current
          end
        end
        current, expired, inactive = groups.values_at(:current, :expired, :inactive).map { |group| group || [] }

        sections = [
          (section(:current, current.map { |certificate| item_for(certificate) }, title: "Current") if current.any?),
          (section(:expired, expired.map { |certificate| item_for(certificate) }, title: "Expired") if expired.any?),
          (section(:inactive, inactive.map { |certificate| item_for(certificate) }, title: "Inactive crew") if inactive.any?)
        ].compact

        { status: :list, answer: join(current_sentence(current), expired_sentence(expired), inactive_sentence(inactive)),
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

          names = current.map { |certificate| "#{certificate.crew_member.display_name} (#{expiry(certificate.expires_on, today: today)})" }
          "#{count(current.size, "person", "people")}#{where_text} #{current.one? ? "holds" : "hold"} a current " \
            "#{certificate_type.name} certificate: #{sentence(names)}."
        end

        def expired_sentence(expired)
          return if expired.empty?

          "Expired: #{sentence(expired.map { |certificate| "#{certificate.crew_member.display_name} (#{date(certificate.expires_on)})" })}."
        end

        def inactive_sentence(inactive)
          return if inactive.empty?

          "Also on file for inactive crew: #{sentence(inactive.map { |certificate| certificate.crew_member.display_name })}."
        end
    end
  end
end
