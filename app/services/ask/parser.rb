module Ask
  # Reads a Question into the things it names, each claiming its own tokens, in order:
  #   1. a time window ("in the next 60 days")
  #   2. a project (by code, or by name when the question is about compliance or expiry)
  #   3. a certificate type and a person, scored over the same remaining words; when their
  #      best windows overlap, an exact match beats a fuzzy one, then the higher score wins,
  #      and the other is re-picked from what is left
  # Pins (ids from a "Did you mean" link) override what the text matched.
  class Parser
    # person_matcher / type_matcher are kept for their near-miss suggestions.
    Parse = Data.define(:question, :window, :project, :person, :type, :leftovers, :person_matcher, :type_matcher) do
      # Text of each leftover run: words nothing explained ("Bob Smith", "scuba").
      def leftover_phrases
        leftovers.map { |range| question.phrase(range) }
      end
    end

    # pins: { crew_member_id:, certificate_type_id:, project_id: }, each optional.
    def initialize(question, today:, pins: {})
      @question = question
      @today = today
      @pins = pins.compact
    end

    def call
      taken = Set.new
      window, window_indexes = TimeWindow.parse(@question, today: @today)
      taken.merge(window_indexes)

      project = pin(ProjectMatcher.new(@question, exclude: taken, fuzzy: @question.project_context?).match, Project, :project_id)
      take(taken, project)

      type_matcher = TypeMatcher.new(@question, exclude: taken.dup)
      person_matcher = PersonMatcher.new(@question, exclude: taken.dup)
      type, person = resolve(type_matcher.hits, person_matcher.hits)
      person = split_name(person, person_matcher.hits, type)
      type = pin(type, CertificateType, :certificate_type_id)
      person = pin(person, CrewMember, :crew_member_id)
      take(taken, type)
      take(taken, person)

      Parse.new(question: @question, window: window, project: project, person: person, type: type,
        leftovers: leftovers(taken), person_matcher: person_matcher, type_matcher: type_matcher)
    end

    private
      def resolve(type_hits, person_hits)
        best_type = Match.pick(type_hits, question: @question)
        best_person = Match.pick(person_hits, question: @question)

        if best_type && best_person && Match.overlap?(best_type.range, best_person.range) &&
            person_first?(person_hits, type_hits, best_person, best_type)
          person = best_person
          type = Match.pick(type_hits, question: @question, blocked: person.range)
        else
          type = best_type
          person = Match.pick(person_hits, question: @question, blocked: type&.range)
        end
        [ type, person ]
      end

      # The person keeps contested words when they were an exact name and the type was a
      # fuzzy guess, or when the person scored higher.
      def person_first?(person_hits, type_hits, person, type)
        person_hit = top_hit(person_hits, person)
        type_hit = top_hit(type_hits, type)
        return person_hit.exact? if person_hit.exact? != type_hit.exact?

        person_hit.score > type_hit.score
      end

      # "Juan Smith" when the roster has Juan Ortiz and Robert Smith: one word matched each,
      # the two together matched nobody. Rather than quietly answer for Juan Ortiz, ask.
      def split_name(person, hits, type)
        return person unless person&.matched? && person.range.size == 1
        return person if top_hit(hits, person)&.rank&.positive?

        neighbours = [ person.range.first - 1, person.range.last + 1 ]
        other = hits.select do |hit|
          hit.record.id != person.record.id && hit.range.size == 1 && neighbours.include?(hit.range.first) &&
            !(type && Match.overlap?(hit.range, type.range))
        end.max_by(&:key)
        return person unless other

        range = [ person.range.first, other.range.first ].min..[ person.range.last, other.range.last ].max
        Match.new(status: :ambiguous, record: person.record, range: range, candidates: [ person.record, other.record ],
          phrase: @question.phrase(range), fuzzy: true)
      end

      def top_hit(hits, match)
        hits.select { |hit| hit.record.id == match.record.id && hit.range == match.range }.max_by(&:key)
      end

      def pin(match, model, key)
        return match unless @pins[key]

        record = model.find_by(id: @pins[key])
        record ? Match.pinned(record, from: match) : match
      end

      def take(taken, match)
        taken.merge(match.range.to_a) if match&.range
      end

      # Runs of free content words: the parts of the question nothing matched.
      def leftovers(taken)
        @question.tokens.reject { |token| taken.include?(token.index) || @question.stopword?(token.index) }
          .chunk_while { |first, second| second.index == first.index + 1 }
          .map { |run| run.first.index..run.last.index }
      end
  end
end
