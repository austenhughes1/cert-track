module Ask
  # A question for the Ask box, split into normalized tokens that remember where they
  # came from in the text, so a matched name can be shown or swapped back in.
  #
  #   question = Ask::Question.new("Does Juan's OSHA-30 expire?")
  #   question.words                # => ["does", "juan", "osha", "30", "expire"]
  #   question.phrase(1..1)         # => "Juan"
  #   question.substitute(1..1, "Juana Ortega") # => "Does Juana Ortega's OSHA-30 expire?"
  #
  # Tokens are lowercased and transliterated ("José" -> "jose"). Possessives are dropped
  # ("Juan's" -> "juan"), letters and digits are split ("osha30" -> "osha", "30") and
  # number words become digits ("thirty" -> "30", "forty-five" and "forty five" -> "45").
  class Question
    Token = Data.define(:text, :index, :start, :stop) do
      def number?
        text.match?(/\A\d+\z/)
      end

      # A lone letter: a middle initial, or the article "a".
      def initial?
        text.length == 1 && !number?
      end
    end

    MAX_LENGTH = 300

    WORD = /[[:alnum:]]+(?:['’][[:alnum:]]+)*['’]?/
    POSSESSIVE = /['’]s?\z/i

    UNIT_WORDS = {
      "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5, "six" => 6, "seven" => 7, "eight" => 8, "nine" => 9
    }.freeze
    TENS_WORDS = {
      "twenty" => 20, "thirty" => 30, "forty" => 40, "fourty" => 40, "fifty" => 50, "sixty" => 60, "seventy" => 70,
      "eighty" => 80, "ninety" => 90
    }.freeze
    NUMBER_WORDS = {
      "zero" => 0, **UNIT_WORDS, "ten" => 10, "eleven" => 11, "twelve" => 12, "thirteen" => 13, "fourteen" => 14,
      "fifteen" => 15, "sixteen" => 16, "seventeen" => 17, "eighteen" => 18, "nineteen" => 19, **TENS_WORDS
    }.transform_values(&:to_s).freeze

    # Words that never name a person, a certificate type or a project on their own. They
    # may still sit inside a type's name ("CDL Class A"), so type windows can contain them.
    STOPWORDS = Set.new(%w[
      a an the and or of for to in on at by with from about as than
      is are was were be been being am do does did done have has had having got get gets getting
      hold holds holding held carry carries carrying possess possesses own owns
      who whos whom whose what whats which when where why how hows
      i im me my mine we us our you your he him his she her hers they them their it its
      this that these those there here
      can could would should will shall may might must
      any anyone anybody anything everyone everybody someone somebody something all every each
      some no none nobody nothing not dont doesnt isnt arent didnt hasnt havent wont without
      please thanks thank tell show list give find see check look lookup let know
      current currently valid still active good ok okay up date dates updated yet ever
      certificate certificates certification certifications certified cert certs card cards
      training trainings trained course courses ticket tickets qualification qualifications
      license licence licenses licences
      person people crew member members worker workers employee employees guy guys staff team folks men
      expire expires expired expiring expiration expirations expiry soon lapse lapses lapsing lapsed
      due renew renewal renewals overdue already
      missing gap gaps lack lacks lacking need needs needed require requires required requirement
      requirements compliance compliant noncompliant non out
      project projects job jobs site sites
      day days week weeks month months year years next within over coming upcoming following
      today tomorrow yesterday last past previous recently lately ago
    ]).freeze

    WHO_WORDS = Set.new(%w[who whos whom anyone anybody everyone everybody someone somebody holders]).freeze
    PEOPLE_WORDS = Set.new(%w[person people crew member members worker workers employee employees guys staff folks men]).freeze
    CHECK_WORDS = Set.new(%w[does do did doesnt didnt has have had hasnt havent is isnt are was got hold holds carry carries possess possesses own owns can]).freeze
    GAP_WORDS = Set.new(%w[missing gap gaps lack lacks lacking noncompliant compliance compliant]).freeze
    EXPIRY_WORDS = Set.new(%w[lapse lapses lapsing lapsed due renew renewal renewals overdue]).freeze
    EXPIRED_WORDS = Set.new(%w[expired lapsed overdue]).freeze
    NEED_WORDS = Set.new(%w[need needs needed require requires required]).freeze
    NEED_SUBJECTS = Set.new(%w[i we you]).freeze # "I need a list of ..." is not about requirements
    NEGATIONS = Set.new(%w[not dont doesnt didnt hasnt havent]).freeze
    POSSESSION_WORDS = Set.new(%w[have has had hold holds held got carry carries own owns possess possesses]).freeze
    PROJECT_WORDS = Set.new(%w[project projects job jobs site sites]).freeze

    attr_reader :text, :tokens

    # The token texts of any string, joined by spaces: the form names and aliases are
    # compared in. Ask::Question.normalize("OSHA 30-Hour") # => "osha 30 hour"
    def self.normalize(text)
      new(text).words.join(" ")
    end

    def initialize(text)
      @text = text.to_s.squish.first(MAX_LENGTH)
      @tokens = tokenize
    end

    def blank?
      tokens.empty?
    end

    def words
      @words ||= tokens.map(&:text)
    end

    def size
      tokens.size
    end

    def stopword?(index)
      STOPWORDS.include?(tokens.fetch(index).text)
    end

    # The original text the tokens in range came from ("Jaun Ortis"), without a trailing
    # possessive.
    def phrase(range)
      text[tokens.fetch(range.first).start...tokens.fetch(range.last).stop]
    end

    # The question with the text behind range replaced, keeping a possessive "'s".
    def substitute(range, replacement)
      start = tokens.fetch(range.first).start
      stop = tokens.fetch(range.last).stop
      "#{text[0...start]}#{replacement}#{text[stop..]}"
    end

    # "Who has ...", "anyone with ...", "which crew have ...".
    def who?
      words.any? { |word| WHO_WORDS.include?(word) } ||
        words.each_cons(2).any? { |first, second| first == "which" && PEOPLE_WORDS.include?(second) }
    end

    # A yes/no question about someone ("does", "has", "is", ...).
    def check?
      words.any? { |word| CHECK_WORDS.include?(word) }
    end

    # Asks about expiry dates ("expir...", "lapse", "renewal", "due").
    def expiring?
      words.any? { |word| word.start_with?("expir") || EXPIRY_WORDS.include?(word) }
    end

    # Asks about certificates that have already run out: "What has expired?", "whose first
    # aid is expired", "Has Li's first aid lapsed?", "did anything expire", "what's past due".
    def expired?
      words.any? { |word| EXPIRED_WORDS.include?(word) } ||
        (words.include?("did") && words.any? { |word| %w[expire lapse].include?(word) }) ||
        words.each_cons(2).include?(%w[past due])
    end

    # Asks about compliance gaps ("missing", "gaps", "compliant", "out of compliance"), or
    # what someone needs ("who needs flagger on 2417", "what does Juan need").
    def gaps?
      words.any? { |word| GAP_WORDS.include?(word) } || needs?
    end

    # "who needs flagger", "required on 2417"; not "I need a list of ...".
    def needs?
      words.each_with_index.any? do |word, index|
        NEED_WORDS.include?(word) && (index.zero? || !NEED_SUBJECTS.include?(words[index - 1]))
      end
    end

    # Negated possession: "who doesn't have flagger", "does not hold", "has no", "without".
    def negated?
      words.include?("without") || words.each_with_index.any? do |word, index|
        (NEGATIONS.include?(word) && words[(index + 1)..(index + 2)].any? { |after| POSSESSION_WORDS.include?(after) }) ||
          (POSSESSION_WORDS.include?(word) && words[index + 1] == "no")
      end
    end

    # Words that make a project name likely ("on the Tower job", "project 2417").
    def project_context?
      gaps? || expiring? || words.any? { |word| PROJECT_WORDS.include?(word) }
    end

    # "When does ...", "what date ..." and "how long ...": the answer leads with the date.
    def asks_when?
      words.first == "when" || words.each_cons(2).any? { |pair| pair == %w[what date] || pair == %w[how long] }
    end

    private
      def tokenize
        parts = []
        text.scan(WORD) do
          match = Regexp.last_match
          core = match[0].sub(POSSESSIVE, "")
          start = match.begin(0)
          normalized = ActiveSupport::Inflector.transliterate(core.delete("'’"), "").downcase
          normalized.scan(/[a-z]+|\d+/).each { |part| parts << [ part, start, start + core.length ] }
        end

        tokens = []
        until parts.empty?
          part, start, stop = parts.shift
          if (number = compound_number(part, stop, parts.first))
            stop = parts.shift.last
            tokens << Token.new(text: number, index: tokens.size, start: start, stop: stop)
          else
            tokens << Token.new(text: NUMBER_WORDS.fetch(part, part), index: tokens.size, start: start, stop: stop)
          end
        end
        tokens
      end

      # "forty-five" or "forty five" -> "45": a tens word, then a units word with only a
      # hyphen or a space between them.
      def compound_number(part, stop, following)
        tens = TENS_WORDS[part]
        return unless tens && following

        units = UNIT_WORDS[following.first]
        (tens + units).to_s if units && following[1] == stop + 1 && text[stop].match?(/[\s-]/)
      end
  end
end
