module Ask
  # Finds certificate types named in a question. Every 1- to 5-word window is scored
  # against every type (retired ones too) in one pg_trgm query, taking the best of:
  #   the code, compared with spaces and punctuation removed ("OSHA 30" -> OSHA30)
  #   similarity and strict_word_similarity to the name and each alias ("cpr" finds
  #   First Aid/CPR/AED, "flager" finds Flagger)
  # Ruby then sorts out:
  #   code / name  the window is the code or a whole name or alias
  #   fuzzy        anything else scoring at least ACCEPT
  # Fuzzy scores use the window's content words only, so "scuba certification" is not the
  # "Flagger Certification" alias just because both say "certification".
  # Numbers must agree: a window, or a number right next to it ("OSHA" in "OSHA 10", also
  # past an "hour" in "10-hour OSHA"), carrying a number the type's name, aliases and code
  # don't have is not that type, so "OSHA 10" never matches OSHA 30. It is offered as a
  # suggestion instead.
  class TypeMatcher
    MAX_WINDOW = 5
    SQL_FLOOR = 0.3
    ACCEPT = 0.5
    MIN_FUZZY_LENGTH = 3 # letters a fuzzy window needs, so "a" or "on" match nothing
    MARGIN = 0.1
    NUMBER_JOINERS = Set.new(%w[hour hours hr hrs]).freeze # "10-hour OSHA": the 10 still belongs to OSHA

    # phrase: every word (exact checks); content: without stopwords (fuzzy scores).
    Window = Data.define(:range, :phrase, :content, :compact, :numbers)

    Hit = Data.define(:record, :range, :score, :kind) do
      def key
        [ exact? ? 1 : 0, score, range.size, record.active? ? 1 : 0 ]
      end

      def exact?
        kind != :fuzzy
      end

      def approximate?
        !exact?
      end

      def rival_of?(top)
        top.exact? ? exact? : score >= top.score - MARGIN
      end
    end

    Names = Data.define(:code, :phrases, :numbers)

    def initialize(question, exclude: Set.new)
      @question = question
      @exclude = exclude
    end

    def hits
      evaluate unless @hits
      @hits
    end

    # Types that came close (or lost on a number), best first.
    def suggestions(limit: 3)
      evaluate unless @near_misses
      @near_misses.sort_by { |hit| -hit.score }.map(&:record).uniq(&:id).first(limit)
    end

    def windows
      @windows ||= free_runs.flat_map { |run| windows_in(run) }
    end

    private
      def evaluate
        @hits = []
        @near_misses = []
        return if windows.empty?

        records = {}
        CertificateType.find_by_sql(scoring_sql).each do |row|
          type = records[row.id] ||= row
          window = windows.fetch(row.ask_window_idx - 1)
          classify(type, window, row.ask_score.to_f)
        end
      end

      def classify(type, window, sql_score)
        names = names_for(type)
        kind = if names.code == window.compact then :code
        elsif names.phrases.include?(window.phrase) then :name
        else :fuzzy
        end
        hit = Hit.new(record: type, range: window.range, score: kind == :fuzzy ? sql_score.clamp(0.0, 0.99) : 1.0, kind: kind)

        if numbers_conflict?(window, names)
          @near_misses << hit
        elsif kind != :fuzzy || (hit.score >= ACCEPT && content_length(window) >= MIN_FUZZY_LENGTH && !trailing_stopword?(window))
          @hits << hit
        else
          @near_misses << hit
        end
      end

      def numbers_conflict?(window, names)
        window.numbers.any? && names.numbers.any? && !window.numbers.subset?(names.numbers)
      end

      def content_length(window)
        window.content.delete(" ").length
      end

      # Only a whole name may end in a stopword ("CDL Class A"); a fuzzy window doesn't
      # take the words after its content ("hazwoper required on", "flager for May").
      def trailing_stopword?(window)
        Question::STOPWORDS.include?(@question.words[window.range.last])
      end

      # Consecutive tokens no other match has taken.
      def free_runs
        @question.tokens.reject { |token| @exclude.include?(token.index) }
          .chunk_while { |first, second| second.index == first.index + 1 }.to_a
      end

      # Windows start on a content word and hold at least one; stopwords may follow
      # ("CDL Class A"), though only an exact name may end on one (#trailing_stopword?).
      def windows_in(run)
        (1..MAX_WINDOW).flat_map do |size|
          run.each_cons(size).filter_map do |tokens|
            next if Question::STOPWORDS.include?(tokens.first.text)

            words = tokens.map(&:text)
            content = words.reject { |word| Question::STOPWORDS.include?(word) }.join(" ")
            Window.new(range: tokens.first.index..tokens.last.index, phrase: words.join(" "), content: content, compact: words.join,
              numbers: (words + adjacent_numbers(tokens)).grep(/\A\d+\z/).to_set)
          end
        end
      end

      # Free number tokens right before or after the window, or past an "hour" there: the 10
      # in "OSHA 10" and in "10-hour OSHA".
      def adjacent_numbers(tokens)
        [ [ tokens.first.index - 1, -1 ], [ tokens.last.index + 1, 1 ] ].filter_map do |index, step|
          index += step if NUMBER_JOINERS.include?(token_at(index)&.text)
          token = token_at(index)
          token.text if token&.number? && !@exclude.include?(index)
        end
      end

      def token_at(index)
        @question.tokens[index] if index >= 0
      end

      def names_for(type)
        @names ||= {}
        @names[type.id] ||= begin
          phrases = [ type.name, *type.aliases ].map { |name| Question.normalize(name) }
          code = Question.normalize(type.code).delete(" ")
          numbers = (phrases.flat_map(&:split) + Question.normalize(type.code).split).grep(/\A\d+\z/).to_set
          Names.new(code: code, phrases: phrases.to_set, numbers: numbers)
        end
      end

      def scoring_sql
        binds = { phrases: windows.map(&:content), compacts: windows.map(&:compact), floor: SQL_FLOOR }
        name = "lower(certificate_types.name::text)"

        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, binds ])
          SELECT certificate_types.*, hits.idx AS ask_window_idx, hits.score AS ask_score
          FROM certificate_types
          CROSS JOIN LATERAL (
            SELECT w.idx, greatest(
                CASE WHEN regexp_replace(lower(certificate_types.code), '[^a-z0-9]+', '', 'g') = w.compact THEN 1.0 ELSE 0 END,
                similarity(#{name}, w.phrase),
                strict_word_similarity(w.phrase, #{name}),
                coalesce((SELECT max(greatest(similarity(lower(a), w.phrase), strict_word_similarity(w.phrase, lower(a))))
                  FROM unnest(certificate_types.aliases) a), 0)
              ) AS score
            FROM unnest(ARRAY[:phrases]::text[], ARRAY[:compacts]::text[]) WITH ORDINALITY AS w(phrase, compact, idx)
          ) hits
          WHERE hits.score >= :floor
          ORDER BY certificate_types.id, hits.idx
        SQL
      end
  end
end
