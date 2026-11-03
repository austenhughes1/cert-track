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

        # Same order as the crew member page: master-list position, then name.
        def type_order(type)
          [ type.position.nil? ? 1 : 0, type.position.to_i, type.name.downcase ]
        end
    end
  end
end
