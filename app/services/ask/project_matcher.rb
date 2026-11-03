module Ask
  # Finds the project a question names: its code ("on 2417", codes of 3+ characters, with
  # spaces and punctuation ignored) or, when the question talks about compliance, expiry
  # or a project, its name by pg_trgm similarity ("Tower 2417 Upgrade", "tower upgrade").
  # The match then takes in neighbouring words of the project's name, so "Tower 2417"
  # leaves no "tower" behind for the type matcher (the Tower Climber alias).
  class ProjectMatcher
    MAX_WINDOW = 4
    CODE_MIN_LENGTH = 3
    SQL_FLOOR = 0.3
    ACCEPT = 0.5
    MARGIN = 0.1
    STATUS_ORDER = { "active" => 2, "planned" => 1, "closed" => 0 }.freeze

    Window = Data.define(:range, :phrase, :compact)

    Hit = Data.define(:record, :range, :score, :kind) do
      def key
        [ exact? ? 1 : 0, score, STATUS_ORDER.fetch(record.status, 0), range.size ]
      end

      def exact?
        kind != :fuzzy
      end

      def approximate?
        !exact?
      end

      def rival_of?(top)
        !top.exact? && score >= top.score - MARGIN
      end
    end

    # fuzzy: also match by name, not just by code.
    def initialize(question, exclude: Set.new, fuzzy: false)
      @question = question
      @exclude = exclude
      @fuzzy = fuzzy
    end

    # Ask::Match or nil.
    def match
      evaluate unless @hits
      match = Match.pick(@hits, question: @question)
      match && extend_over_name(match)
    end

    # Projects whose name resembles phrase, active ones first; every active project when
    # none does. For "I couldn't find a project matching ...".
    def self.suggestions(phrase, limit: 3)
      similar = Project.where("similarity(lower(projects.name), :phrase) >= 0.2 OR lower(projects.code) = :phrase", phrase: phrase.downcase)
        .order(Arel.sql(ActiveRecord::Base.sanitize_sql_array([ "similarity(lower(projects.name), ?) DESC", phrase.downcase ])))
        .limit(limit).to_a
      similar.presence || Project.active.ordered.limit(limit).to_a
    end

    private
      def evaluate
        @hits = []
        return if windows.empty?

        records = {}
        Project.find_by_sql(scoring_sql).each do |row|
          project = records[row.id] ||= row
          window = windows.fetch(row.ask_window_idx - 1)
          score = row.ask_score.to_f
          kind = if score >= 2.0 then :code
          elsif Question.normalize(project.name) == window.phrase then :name
          else :fuzzy
          end
          next if kind == :fuzzy && score < ACCEPT

          @hits << Hit.new(record: project, range: window.range, score: kind == :fuzzy ? score : 1.0, kind: kind)
        end
      end

      def windows
        @windows ||= @question.tokens.reject { |token| @exclude.include?(token.index) }
          .chunk_while { |first, second| second.index == first.index + 1 }
          .flat_map do |run|
            (1..MAX_WINDOW).flat_map do |size|
              run.each_cons(size).filter_map do |tokens|
                next if Question::STOPWORDS.include?(tokens.first.text) || Question::STOPWORDS.include?(tokens.last.text)

                words = tokens.map(&:text)
                Window.new(range: tokens.first.index..tokens.last.index, phrase: words.join(" "), compact: words.join)
              end
            end
          end
      end

      def scoring_sql
        binds = { phrases: windows.map(&:phrase), compacts: windows.map(&:compact), fuzzy: @fuzzy,
          min: CODE_MIN_LENGTH, floor: SQL_FLOOR }

        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, binds ])
          SELECT projects.*, hits.idx AS ask_window_idx, hits.score AS ask_score
          FROM projects
          CROSS JOIN LATERAL (
            SELECT w.idx,
              CASE WHEN length(w.compact) >= :min
                  AND regexp_replace(lower(coalesce(projects.code, '')), '[^a-z0-9]+', '', 'g') = w.compact THEN 2.0
                WHEN :fuzzy THEN similarity(lower(projects.name), w.phrase)
                ELSE 0
              END AS score
            FROM unnest(ARRAY[:phrases]::text[], ARRAY[:compacts]::text[]) WITH ORDINALITY AS w(phrase, compact, idx)
          ) hits
          WHERE hits.score >= :floor
          ORDER BY projects.id, hits.idx
        SQL
      end

      # Grows the range over free neighbouring words that belong to the project's name.
      def extend_over_name(match)
        name_words = Question.new("#{match.record.name} #{match.record.code}").words.to_set
        first = match.range.first
        last = match.range.last
        first -= 1 while first.positive? && extendable?(first - 1, name_words)
        last += 1 while last + 1 < @question.size && extendable?(last + 1, name_words)
        range = first..last
        match.with(range: range, phrase: @question.phrase(range))
      end

      def extendable?(index, name_words)
        !@exclude.include?(index) && name_words.include?(@question.words[index]) && !@question.stopword?(index)
      end
  end
end
