module Ask
  # How a person, certificate type or project was found in a question.
  #   status     :matched, or :ambiguous when rivals scored about as well
  #   record     the best record
  #   range      token indexes it was read from (nil when pinned by id)
  #   candidates the best record and its rivals, best first (just [record] when matched)
  #   phrase     the question text it was read from ("Jaun Ortis")
  #   fuzzy      true when the text was not exactly a name, code or alias (a typo, a nickname)
  Match = Data.define(:status, :record, :range, :candidates, :phrase, :fuzzy) do
    # Best match among hits (PersonMatcher::Hit, TypeMatcher::Hit, ProjectMatcher::Hit):
    # each record's best hit competes, and records whose best hit overlaps the winner's
    # tokens and is nearly as good make the match ambiguous. Hits overlapping blocked (a
    # range another kind of match already took) are ignored. nil when no hit is left.
    def self.pick(hits, question:, blocked: nil)
      hits = hits.reject { |hit| blocked && Match.overlap?(hit.range, blocked) }
      best = hits.group_by { |hit| hit.record.id }.values.map { |record_hits| record_hits.max_by(&:key) }
      top = best.max_by(&:key)
      return unless top

      rivals = best.reject { |hit| hit.equal?(top) }
        .select { |hit| Match.overlap?(hit.range, top.range) && hit.rival_of?(top) }
        .sort_by(&:key).reverse

      new(status: rivals.any? ? :ambiguous : :matched, record: top.record, range: top.range,
        candidates: [ top, *rivals ].map(&:record), phrase: question.phrase(top.range), fuzzy: top.approximate?)
    end

    # A record chosen by id (a "Did you mean" link), keeping the range the text matched.
    def self.pinned(record, from: nil)
      new(status: :matched, record: record, range: from&.range, candidates: [ record ], phrase: from&.phrase, fuzzy: false)
    end

    def self.overlap?(first, second)
      first.first <= second.last && second.first <= first.last
    end

    def matched?
      status == :matched
    end

    def ambiguous?
      status == :ambiguous
    end
  end
end
