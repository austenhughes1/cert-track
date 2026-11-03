module Ask
  module Answers
    # "What does Juan Ortiz have?" Every current (not superseded) certificate the person
    # holds, each with its status, expired ones included.
    class Certificates < Base
      def call
        certificates = person.current_certificates.includes(:certificate_type).to_a
          .sort_by { |certificate| type_order(certificate.certificate_type) }
        certificates.each { |certificate| certificate.association(:crew_member).target = person }

        { status: :list, answer: join(summary(certificates), inactive_note(person)), crew_member: person,
          crew_members: [ person ], certificates: certificates,
          sections: [ section(:certificates, certificates.map { |certificate| item_for(certificate) }, title: "Certificates") ] }
      end

      private
        def summary(certificates)
          name = person.display_name
          return "#{name} has no certificates on file." if certificates.empty?

          listed = certificates.map { |certificate| "#{certificate.certificate_type.name} (#{expiry(certificate.expires_on, today: today)})" }
          "#{name} has #{count(certificates.size, "certificate")} on file: #{sentence(listed)}."
        end
    end
  end
end
