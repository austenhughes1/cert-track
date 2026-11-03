module Ask
  # The date range a question about expiry covers (inclusive).
  # Ahead, from today:
  #   "in 60 days", "within 90 days", "next 2 weeks", "over the next 3 months" -> today + N
  #   "in a week", "within a year", "next week", "next month", "next year"   -> today + 1 unit
  #   "this week", "this month", "this year"                                   -> to the end of it
  #   "today", "tomorrow"
  # Behind (past: true), up to yesterday, for what has already expired:
  #   "in the last 60 days", "past 2 weeks", "last month", "in the past year"  -> today - N .. yesterday
  #   "recently", "lately" (the last 30 days), "yesterday"
  # Anything else is the default: the next 30 days.
  TimeWindow = Data.define(:from, :to, :label, :explicit, :past)

  class TimeWindow
    DEFAULT_DAYS = Compliance::EXPIRING_WINDOW
    MAX_DAYS = 3660 # ten years; beyond that a question isn't about expiry soon

    UNITS = {
      "day" => :days, "days" => :days, "d" => :days,
      "week" => :weeks, "weeks" => :weeks, "wk" => :weeks, "wks" => :weeks,
      "month" => :months, "months" => :months, "mo" => :months, "mos" => :months,
      "year" => :years, "years" => :years, "yr" => :years, "yrs" => :years
    }.freeze
    LEADS = %w[in within next the over coming upcoming following].freeze
    RELATIVE = %w[next coming following].freeze
    PAST = %w[last past previous].freeze
    ARTICLES = %w[a an].freeze # "in a week": one unit
    ARTICLE_LEADS = %w[in within over].freeze
    RECENT = %w[recently lately].freeze

    def initialize(from:, to:, label:, explicit:, past: false)
      super
    end

    # [TimeWindow, token indexes it was read from]. The default window comes with no indexes.
    def self.parse(question, today:)
      words = question.words
      words.each_with_index do |word, index|
        unit = UNITS[words[index + 1]]
        if PAST.include?(word) && (count, unit, last = quantity(words, index + 1))
          return [ span_back(count, unit, today), with_leads(words, index, last) ]
        elsif word.match?(/\A\d+\z/) && unit
          return [ span(word.to_i, unit, today), with_leads(words, index, index + 1) ]
        elsif RELATIVE.include?(word) && unit && singular?(words[index + 1])
          return [ span(1, unit, today), with_leads(words, index, index + 1) ]
        elsif ARTICLES.include?(word) && unit && singular?(words[index + 1]) && index.positive? && ARTICLE_LEADS.include?(words[index - 1])
          return [ span(1, unit, today), with_leads(words, index, index + 1) ]
        elsif word == "this" && unit
          return [ calendar(unit, today), [ index, index + 1 ] ]
        elsif word == "today" || word == "tomorrow"
          days = word == "today" ? 0 : 1
          return [ new(from: today, to: today + days, label: word, explicit: true), [ index ] ]
        elsif word == "yesterday"
          return [ new(from: today - 1, to: today - 1, label: word, explicit: true, past: true), [ index ] ]
        elsif RECENT.include?(word)
          return [ span_back(DEFAULT_DAYS, :days, today, label: "in the last #{DEFAULT_DAYS} days"), [ index ] ]
        end
      end
      [ default(today: today), [] ]
    end

    def self.default(today:)
      new(from: today, to: today + DEFAULT_DAYS, label: "in the next #{DEFAULT_DAYS} days", explicit: false)
    end

    # What follows "last" / "past": "60 days", "2 weeks", "a month", or a bare "month".
    # [count, unit, index of the unit word], or nil.
    def self.quantity(words, index)
      word = words[index]
      if word&.match?(/\A\d+\z/) && UNITS[words[index + 1]]
        [ word.to_i, UNITS[words[index + 1]], index + 1 ]
      elsif ARTICLES.include?(word) && UNITS[words[index + 1]] && singular?(words[index + 1])
        [ 1, UNITS[words[index + 1]], index + 1 ]
      elsif UNITS[word] && singular?(word)
        [ 1, UNITS[word], index ]
      end
    end

    def self.singular?(unit_word)
      !unit_word.to_s.end_with?("s")
    end

    def self.span(count, unit, today)
      new(from: today, to: shift(today, count, unit, 1), label: "in the next #{amount(count, unit)}", explicit: true)
    end

    def self.span_back(count, unit, today, label: "in the last #{amount(count, unit)}")
      new(from: shift(today, count, unit, -1), to: today - 1, label: label, explicit: true, past: true)
    end

    # today moved count units forward (direction 1) or back (-1), capped at MAX_DAYS.
    def self.shift(today, count, unit, direction)
      case unit
      when :days then today + (direction * [ count, MAX_DAYS ].min)
      when :weeks then today + (direction * [ count * 7, MAX_DAYS ].min)
      when :months then today.advance(months: direction * [ count, MAX_DAYS / 30 ].min)
      else today.advance(years: direction * [ count, MAX_DAYS / 365 ].min)
      end
    end

    # "week", "3 months"
    def self.amount(count, unit)
      noun = unit.to_s.singularize
      count == 1 ? noun : "#{count} #{noun.pluralize}"
    end

    def self.calendar(unit, today)
      to = case unit
      when :days then today
      when :weeks then today.end_of_week
      when :months then today.end_of_month
      else today.end_of_year
      end
      new(from: today, to: to, label: "this #{unit.to_s.singularize}", explicit: true)
    end

    # The words read plus the "in the next" / "in the" words just before them.
    def self.with_leads(words, first, last)
      first -= 1 while first.positive? && LEADS.include?(words[first - 1])
      (first..last).to_a
    end

    private_class_method :quantity, :singular?, :span, :span_back, :shift, :amount, :calendar, :with_leads

    def range
      from..to
    end

    def days
      (to - from).to_i
    end
  end
end
