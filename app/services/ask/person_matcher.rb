module Ask
  # Finds crew members named in a question. Every 1- to 3-word window of the question's
  # name-like words (and its nickname variants: "Bob" -> "Robert") is scored against every
  # crew member in one pg_trgm query:
  #   2-3 words: similarity to the full name, preferred + last name and each alias
  #   1 word:    strict_word_similarity to those, so a lone first or last name can match
  # Ruby then refines the rows the query returns:
  #   exact  the window normalizes to one of the member's names (NameNormalizer), or its
  #          first and last name: "Juan A. Ortiz", "Mari Garcia", "Jon Ortiz" (an alias)
  #   part   a single word equal to one of their name words: "Ortiz", "Juan", "Mari"
  #   fuzzy  max(trigram score, letter-edit score), so "Jaun Ortis" still finds Juan Ortiz
  # Hits rank exact > part/fuzzy, then longer windows, then score (see Hit#key and Match.pick).
  class PersonMatcher
    MAX_WINDOW = 3
    SQL_FLOOR = 0.2 # rows the query returns; Ruby decides what counts
    ACCEPT_MULTI = 0.6 # fuzzy score a 2-3 word window needs
    ACCEPT_SINGLE = 0.75 # a single word must be closer: "ortis" -> Ortiz, not "scott" -> Scotti
    SUGGEST = 0.35 # near misses offered as "Did you mean ...?" when nobody matches
    MIN_TOKEN_SIMILARITY = 0.6 # every word must be close for the edit score to count
    MARGIN = 0.15 # rivals this close to the best make the match ambiguous
    NICKNAME_PENALTY = 0.05 # "Rob" is Rob Jones before it is Robert Smith

    Window = Data.define(:range, :phrase, :nickname) do
      def single?
        !phrase.include?(" ")
      end
    end

    # rank: 2 exact, 1 exact through a nickname, 0 part or fuzzy.
    Hit = Data.define(:record, :range, :score, :rank, :kind) do
      def key
        [ rank, range.size, score ]
      end

      def exact?
        kind != :fuzzy
      end

      # Read through a typo or a nickname rather than as written.
      def approximate?
        score < 1.0 || rank == 1
      end

      def rival_of?(top)
        rank == top.rank && range.size == top.range.size && score >= top.score - MARGIN
      end
    end

    Names = Data.define(:exact, :lists, :words)

    def initialize(question, exclude: Set.new)
      @question = question
      @exclude = exclude
    end

    # Accepted hits, every window and member.
    def hits
      evaluate unless @hits
      @hits
    end

    # Members that came close without matching, best first.
    def suggestions(limit: 3)
      evaluate unless @near_misses
      @near_misses.sort_by { |hit| -hit.score }.map(&:record).uniq(&:id).first(limit)
    end

    def windows
      @windows ||= runs.flat_map { |run| windows_in(run) }.flat_map { |window| with_nicknames(window) }
    end

    private
      def evaluate
        @hits = []
        @near_misses = []
        return if windows.empty?

        CrewMember.find_by_sql(scoring_sql).each do |member|
          window = windows.fetch(member.ask_window_idx - 1)
          hit = refine(member, window, member.ask_score.to_f)
          next unless hit

          accepted = hit.rank.positive? || hit.score >= (window.single? ? ACCEPT_SINGLE : ACCEPT_MULTI)
          if accepted
            @hits << hit
          elsif hit.score >= SUGGEST
            @near_misses << hit
          end
        end
        dedupe_records!
      end

      # Runs of name-like tokens: not taken by another match, not a stopword or number. A
      # lone letter joins a run as an initial ("Juan A. Ortiz").
      def runs
        @question.tokens.slice_when { |first, second| !name_like?(first) || !name_like?(second) }
          .select { |run| run.all? { |token| name_like?(token) } }
      end

      def name_like?(token)
        return false if @exclude.include?(token.index) || token.number?

        token.initial? || !Question::STOPWORDS.include?(token.text)
      end

      def windows_in(run)
        (1..MAX_WINDOW).flat_map do |size|
          run.each_cons(size).filter_map do |tokens|
            next if tokens.last.initial? || (size == 1 && tokens.first.text.length < 2)

            phrase = NameNormalizer.normalize(tokens.map(&:text).join(" "))
            Window.new(range: tokens.first.index..tokens.last.index, phrase: phrase, nickname: false) if phrase.present?
          end
        end
      end

      # The window itself, then each spelling with nicknames swapped in ("bob smith" ->
      # "robert smith"), capped so a long window can't explode.
      def with_nicknames(window)
        options = window.phrase.split.map { |word| [ word, *Nicknames.expand(word) ] }
        variants = options.first.product(*options.drop(1)).map { |words| words.join(" ") }.first(8)
        variants.each_with_index.map do |phrase, index|
          Window.new(range: window.range, phrase: phrase, nickname: index.positive?)
        end
      end

      def scoring_sql
        phrases = windows.map(&:phrase)
        singles = windows.map(&:single?)
        alias_similarity = "coalesce((select max(similarity(lower(a), w.phrase)) from unnest(crew_members.name_aliases) a), 0)"
        alias_word_similarity = "coalesce((select max(strict_word_similarity(w.phrase, lower(a))) from unnest(crew_members.name_aliases) a), 0)"

        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, { phrases: phrases, singles: singles, floor: SQL_FLOOR } ])
          SELECT crew_members.*, hits.idx AS ask_window_idx, hits.score AS ask_score
          FROM crew_members
          CROSS JOIN LATERAL (
            SELECT w.idx,
              CASE WHEN w.single THEN greatest(
                  strict_word_similarity(w.phrase, #{CrewMember::FULL_NAME_SQL}),
                  strict_word_similarity(w.phrase, #{CrewMember::PREFERRED_NAME_SQL}),
                  #{alias_word_similarity})
                ELSE greatest(
                  similarity(#{CrewMember::FULL_NAME_SQL}, w.phrase),
                  similarity(#{CrewMember::PREFERRED_NAME_SQL}, w.phrase),
                  #{alias_similarity})
              END AS score
            FROM unnest(ARRAY[:phrases]::text[], ARRAY[:singles]::boolean[]) WITH ORDINALITY AS w(phrase, single, idx)
          ) hits
          WHERE hits.score >= :floor
          ORDER BY crew_members.id, hits.idx
        SQL
      end

      def refine(member, window, sql_score)
        names = names_for(member)
        words = window.phrase.split

        if window.single?
          if names.words.include?(words.first)
            Hit.new(record: member, range: window.range, rank: 0, kind: :part,
              score: window.nickname ? 1.0 - NICKNAME_PENALTY : 1.0)
          else
            score = [ sql_score, names.words.map { |word| TextDistance.similarity(words.first, word) }.max.to_f ].max
            fuzzy_hit(member, window, score)
          end
        elsif names.exact.include?(window.phrase)
          Hit.new(record: member, range: window.range, score: 1.0, rank: window.nickname ? 1 : 2, kind: :exact)
        else
          fuzzy_hit(member, window, [ sql_score, edit_score(words, names.lists) ].max)
        end
      end

      def fuzzy_hit(member, window, score)
        score -= NICKNAME_PENALTY if window.nickname
        Hit.new(record: member, range: window.range, score: score.clamp(0.0, 0.99), rank: 0, kind: :fuzzy)
      end

      # Mean letter-edit similarity of the words, position by position, against the best
      # name of the same length. 0 when any word is far off ("juan smith" is not Jane Smith).
      def edit_score(words, lists)
        lists.select { |list| list.size == words.size }.map do |list|
          scores = words.zip(list).map { |word, name_word| TextDistance.similarity(word, name_word) }
          scores.min >= MIN_TOKEN_SIMILARITY ? scores.sum / scores.size : 0.0
        end.max.to_f
      end

      def names_for(member)
        @names ||= {}
        @names[member.id] ||= begin
          lists = member.normalized_names.map(&:split)
          lists += lists.select { |list| list.size > 2 }.map { |list| [ list.first, list.last ] }
          Names.new(exact: lists.map { |list| list.join(" ") }.to_set, lists: lists.uniq, words: lists.flatten.to_set)
        end
      end

      # find_by_sql returns one instance per row; keep one per member so hits compare by identity.
      def dedupe_records!
        records = {}
        [ @hits, @near_misses ].each do |list|
          list.map! { |hit| hit.with(record: records[hit.record.id] ||= hit.record) }
        end
      end
  end
end
