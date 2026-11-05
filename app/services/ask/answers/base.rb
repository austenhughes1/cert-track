module Ask
  module Answers
    # An answer to one intent, built from an Ask::Parser::Parse whose required matches
    # are present and unambiguous (AskQuery checks that first). #call returns the
    # AskQuery::Result attributes it sets: status, answer and the evidence.
    class Base
      include Wording

      LIST_LIMIT = 50 # evidence rows per section

      def initialize(parse, today:)
        @parse = parse
        @today = today
      end

      private
        attr_reader :parse, :today

        def person
          parse.person&.record
        end

        def certificate_type
          parse.type&.record
        end

        def project
          parse.project&.record
        end

        def window
          parse.window
        end

        def question
          parse.question
        end

        def inactive_note(member)
          "#{member.display_name} is marked inactive." unless member.active?
        end

        def join(*sentences)
          sentences.compact_blank.join(" ")
        end

        def section(key, items, title: nil)
          Section.new(key: key, title: title, items: items.first(LIST_LIMIT), total: items.size)
        end

        def item_for(certificate, status: nil, project: nil)
          Item.new(crew_member: certificate.crew_member, certificate_type: certificate.certificate_type,
            certificate: certificate, status: status || Compliance.status_for(certificate, today: today), project: project)
        end

        # "missing", "expired Oct 29, 2026" or "confirmed fake: not found by issuer", for a
        # Compliance::ProjectReport::Gap.
        def gap_state(gap)
          case gap.status
          when "expired" then with_authenticity("expired #{date(gap.certificate.expires_on)}", gap.certificate)
          when "fake" then confirmed_fake(gap.certificate)
          else "missing"
          end
        end

        # "confirmed fake: not found by issuer" or "flagged for review: suspicious link" for a listed
        # certificate whose authenticity is flagged, else nil. Only a confirmed fake one stops counting.
        def authenticity_text(certificate)
          if certificate.authenticity_confirmed_fake? then confirmed_fake(certificate)
          elsif certificate.authenticity_flagged_for_review? then flagged_for_review(certificate)
          end
        end

        # " (flagged for review: not found by issuer)" after a listed certificate whose authenticity
        # is flagged, as authenticity_text.
        def authenticity_note(certificate)
          text = authenticity_text(certificate)
          " (#{text})" if text
        end

        # "expired Oct 29, 2026; flagged for review: doesn't match issuer": the details that go in
        # a listed certificate's parentheses, then its authenticity_text when it has one.
        def with_authenticity(details, certificate)
          [ details, (authenticity_text(certificate) if certificate) ].compact.join("; ")
        end

        # Same order as the crew member page: master-list position, then name.
        def type_order(type)
          [ type.position.nil? ? 1 : 0, type.position.to_i, type.name.downcase ]
        end
    end
  end
end
