module Ask
  module Answers
    # "Does Juan Ortiz have OSHA 30?" Looks at the person's current certificate of the type:
    #   Yes. Juan Ortiz has OSHA 30 Construction, completed Mar 14, 2025, no expiration.
    #   Yes. Juan Ortiz has Flagger, completed Nov 15, 2023, but it expires in 12 days (Nov 15, 2026).
    #   No. Juan Ortiz has no current Flagger certificate; the last one expired Aug 2, 2026.
    #   No. Juan Ortiz has no Flagger certificate on file.
    #   No. Juan Ortiz's Flagger certificate is confirmed fake (not found by issuer), so it doesn't count.
    #   Yes. Li Chen's First Aid/CPR/AED expired Oct 29, 2026, but it is confirmed fake (...), so it doesn't count.
    # One only flagged for review (an automatic check, a QR code's details, a lookalike link) is
    # answered by its dates, then says so:
    #   Yes. Juan Ortiz has Flagger, ... It's flagged for review (not found by issuer) but still counts
    #   until someone checks it with the issuer.
    # "Is Juan missing ...?", "Does Juan need ...?" and "Has Juan's ... expired?" ask the
    # opposite question, so the leading Yes/No swaps; "When does ...?" leads with the date.
    # status is :yes when the person holds a current, unexpired certificate that isn't confirmed
    # fake, else :no.
    class Check < Base
      def call
        certificate = person.current_certificate_for(certificate_type)
        if certificate
          certificate.association(:crew_member).target = person
          certificate.association(:certificate_type).target = certificate_type
        end
        status = Compliance.status_for(certificate, today: today)
        holds = %w[valid expiring].include?(status)

        item = Item.new(crew_member: person, certificate_type: certificate_type, certificate: certificate, status: status)
        { status: holds ? :yes : :no,
          answer: join(answer_sentence(certificate, status), review_note(certificate, status), inactive_note(person)),
          crew_member: person, crew_members: [ person ], certificates: [ certificate ].compact,
          sections: [ section(:evidence, [ item ]) ] }
      end

      private
        def answer_sentence(certificate, status)
          return when_sentence(certificate, status) if question.asks_when?

          name = person.display_name
          type = certificate_type.name
          case status
          when "missing"
            "#{lead(false)} #{name} has no #{type} certificate on file."
          when "expired"
            "#{lead(false)} #{name} has no current #{type} certificate; the last one expired #{date(certificate.expires_on)}."
          when "fake"
            if question.expired? && !question.gaps? # asks about the date, so it gives it
              "#{fake_lead(certificate)} #{possessive(name)} #{type} #{fake_expiry(certificate)}, but it #{doesnt_count(certificate)}"
            else
              "#{fake_lead(certificate)} #{possessive(name)} #{type} certificate #{doesnt_count(certificate)}"
            end
          when "expiring"
            days = certificate.days_until_expiry(today: today)
            "#{lead(true)} #{name} has #{type}, completed #{date(certificate.completed_on)}, " \
              "but it expires #{in_days(days)} (#{date(certificate.expires_on)})."
          else
            ending = certificate.expires_on ? "expires #{date(certificate.expires_on)}" : "no expiration"
            "#{lead(true)} #{name} has #{type}, completed #{date(certificate.completed_on)}, #{ending}."
          end
        end

        # "Is Juan missing Flagger?" and "Has Li's first aid expired?" ask the opposite
        # question (does the person lack it?), so Yes and No swap.
        def lead(holds)
          asks_lack = question.gaps? || question.expired?
          holds == asks_lack ? "No." : "Yes."
        end

        # "Has Juan's flagger expired?" is answered by the date (it may not have, yet still not
        # count); every other question by whether it counts, as for a missing one.
        def fake_lead(certificate)
          return lead(false) unless question.expired? && !question.gaps?

          certificate.expires_on&.before?(today) ? "Yes." : "No."
        end

        def when_sentence(certificate, status)
          owner = "#{possessive(person.display_name)} #{certificate_type.name}"
          case status
          when "missing" then "#{person.display_name} has no #{certificate_type.name} certificate on file."
          when "expired" then "#{owner} expired #{date(certificate.expires_on)}; there is no current one."
          when "fake" then "#{owner} #{fake_expiry(certificate)}, but it #{doesnt_count(certificate)}"
          else
            if certificate.expires_on
              "#{owner} expires #{date(certificate.expires_on)} (#{in_days(certificate.days_until_expiry(today: today))})."
            else
              "#{owner} never expires (completed #{date(certificate.completed_on)})."
            end
          end
        end

        def doesnt_count(certificate)
          "is confirmed fake (#{certificate.authenticity_label.downcase}), so it doesn't count."
        end

        def fake_expiry(certificate)
          days = certificate.days_until_expiry(today: today)
          if days.nil? then "never expires"
          elsif days.negative? then "expired #{date(certificate.expires_on)}"
          else "expires #{date(certificate.expires_on)} (#{in_days(days)})"
          end
        end

        # Flagged for review only: it keeps the answer its dates give it (a confirmed fake one
        # already says why it doesn't count).
        def review_note(certificate, status)
          return unless certificate&.authenticity_flagged_for_review?

          reason = certificate.authenticity_label.downcase
          if status == "expired" then "It's also flagged for review (#{reason})."
          else "It's flagged for review (#{reason}) but still counts until someone checks it with the issuer."
          end
        end
    end
  end
end
