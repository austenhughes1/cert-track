# The Ask box (docs/PLAN.md "Ask box"): answers plain-English certificate questions
# straight from the database. No AI and no network; every role may ask.
#
#   result = AskQuery.new("Does Juan have OSHA 30?", user: Current.user).call
#   result.intent # => :check
#   result.status # => :yes
#   result.answer # => "Yes. Juan Ortiz has OSHA 30 Construction, completed Mar 14, 2025, no expiration."
#
# How a question is read (Ask::Parser): a time window, then a project, then a certificate
# type and a person, each by pg_trgm fuzzy matching plus nicknames. The intent follows
# from what was found and a few keywords:
#   person + type                      :check              "Does Juan Ortiz have OSHA 30?"
#   project + "required", "needs"      :requirements       "What's required on 2417?", "requirements for 2417"
#     (no person, not "who")
#   "missing", "gaps", "compliant",    :gaps               "What's missing on 2417?", "who needs flagger on 2417"
#     "needs", "required" (otherwise)
#   "doesn't have", "without" + type   :lacking            "Who doesn't have Flagger?"
#     (no type: :gaps)                                     "What doesn't Juan have?"
#   "expired", "lapsed", "past due",   :expired            "Which certificates have expired?", "what expired last month"
#     "out of date", "no longer valid",                    "what's out of date", "any lapses?"
#     or expiry words with a past window
#   "expir...", "renewal", "due"       :expiring           "What expires in the next 60 days?"
#   type                               :list_holders       "Who has Flagger?"
#   person                             :list_certificates  "What does Juan have?", "Juan's certs"
#   nothing recognisable               :unknown            (help text)
# Status: :yes / :no (check), :list (the other answers), :ambiguous ("Did you mean Juan
# Ortiz or Juana Ortega?", with candidates), :not_found ("I couldn't find ..."), :unknown.
#
# Pins (crew_member_id:, certificate_type_id:, project_id:) come from "Did you mean" links
# and override what the text matched, so two people with one name can be told apart.
class AskQuery
  INTENTS = %i[check list_holders list_certificates lacking expiring expired gaps requirements unknown].freeze
  STATUSES = %i[yes no list ambiguous not_found unknown].freeze
  LIST_LIMIT = Ask::Answers::Base::LIST_LIMIT

  HELP = "I can tell you whether someone holds a certificate, who holds one, what one person has, " \
    "what expires soon, what a project requires and what's missing on it. Try one of the examples.".freeze

  # question         the question as asked (squished)
  # intent, status   see above
  # answer           plain text naming the evidence
  # crew_member      the person the question was about, if any
  # crew_members     everyone the answer is about (holders, people with gaps, ...)
  # certificate_type the type the question was about, if any
  # project          the project the question named, if any
  # certificates     the certificates behind the answer, for linking
  # candidates       Array<Ask::Candidate> for "Did you mean ...?"
  # sections         Array<Ask::Section> of Ask::Item evidence rows
  # notes            short asides ("Matched “Jaun Ortis” to Juan Ortiz.")
  # window           the Ask::TimeWindow of an expiring answer, or the past one ("last
  #                  month") of an expired answer
  Result = Data.define(:question, :intent, :status, :answer, :crew_member, :crew_members, :certificate_type,
    :project, :certificates, :candidates, :sections, :notes, :window) do
    def evidence
      sections.flat_map(&:items)
    end

    def answered?
      %i[yes no list].include?(status)
    end
  end

  EMPTY = { crew_member: nil, crew_members: [], certificate_type: nil, project: nil, certificates: [],
    candidates: [], sections: [], notes: [], window: nil }.freeze

  ANSWERS = {
    check: Ask::Answers::Check, list_holders: Ask::Answers::Holders, list_certificates: Ask::Answers::Certificates,
    lacking: Ask::Answers::Lacking, expiring: Ask::Answers::Expiring, expired: Ask::Answers::Expired, gaps: Ask::Answers::Gaps,
    requirements: Ask::Answers::Requirements
  }.freeze

  attr_reader :user, :today

  def initialize(text, user:, today: Date.current, crew_member_id: nil, certificate_type_id: nil, project_id: nil)
    @text = text
    @user = user
    @today = today
    @pins = { crew_member_id: crew_member_id, certificate_type_id: certificate_type_id, project_id: project_id }.compact
  end

  def call
    question = Ask::Question.new(@text)
    return result(question, :unknown, status: :unknown, answer: HELP) if question.blank?

    parse = Ask::Parser.new(question, today: today, pins: @pins).call
    intent = intent_for(parse)
    return result(question, :unknown, status: :unknown, answer: "I'm not sure what you're asking. #{HELP}") if intent == :unknown

    attributes = clarification(parse, intent) || ANSWERS.fetch(intent).new(parse, today: today).call
    notes = notes(parse, answered: attributes[:status].in?(%i[yes no list]))
    result(question, intent, **found(parse), notes: notes, **attributes, window: window_for(parse, intent))
  end

  private
    def result(question, intent, **attributes)
      Result.new(**EMPTY, question: question.text, intent: intent, **attributes)
    end

    def intent_for(parse)
      question = parse.question
      leftovers = parse.leftovers.any?

      if parse.person && parse.type then :check
      elsif parse.project && parse.person.nil? && question.requirements? then :requirements
      elsif question.gaps? then :gaps
      elsif question.negated? then negated_intent(parse)
      elsif expired?(parse) then :expired
      elsif question.expiring? then :expiring
      elsif parse.type then leftovers && question.check? && !question.who? ? :check : :list_holders
      elsif parse.person then leftovers && question.check? ? :check : :list_certificates
      elsif parse.project then :gaps
      elsif leftovers then unmatched_intent(parse)
      else :unknown
      end
    end

    # "Who doesn't have flagger?" lists the people without one; with no type named ("What
    # doesn't Juan have?", "who doesn't have their certs") it is a gaps question.
    def negated_intent(parse)
      if parse.type then :lacking
      elsif parse.person || parse.project then :gaps
      elsif parse.leftovers.any? && parse.question.who? then :lacking # "who doesn't have scuba": say what's unknown
      else :gaps
      end
    end

    # "What has expired?", "what lapsed last month": certificates already past their expiry.
    # A forward window ("expired by next month") leaves it an expiring question.
    def expired?(parse)
      question = parse.question
      window = parse.window
      (question.expired? && (window.past || !window.explicit)) || (question.expiring? && window.past)
    end

    def window_for(parse, intent)
      parse.window if intent == :expiring || (intent == :expired && parse.window.past)
    end

    # Words that matched nothing, in a question shaped like a lookup: say what couldn't be
    # found rather than give up. Without that shape, only near misses count.
    def unmatched_intent(parse)
      question = parse.question
      if question.who? then :list_holders
      elsif question.check? then question.words.first == "what" ? :list_certificates : :check
      elsif parse.type_matcher.suggestions.any? then :list_holders
      elsif parse.person_matcher.suggestions.any? then :list_certificates
      else :unknown
      end
    end

    def found(parse)
      { crew_member: parse.person&.record, crew_members: [ parse.person&.record ].compact,
        certificate_type: parse.type&.record, project: parse.project&.record }
    end

    # An ambiguous match, or a required one that is missing, comes back as a question.
    def clarification(parse, intent)
      unclear = [ parse.person, parse.type, parse.project ].compact.find(&:ambiguous?)
      return ambiguous(parse, unclear) if unclear

      phrases = parse.leftover_phrases
      missing_person = intent.in?(%i[check list_certificates]) && parse.person.nil?
      missing_type = intent.in?(%i[check list_holders lacking]) && parse.type.nil?

      if missing_person && missing_type && phrases.size > 1
        not_found(parse, "I couldn't find a crew member named #{Ask::Wording.quote(phrases.first)} or a certificate type " \
          "matching #{Ask::Wording.quote(phrases.last)}.", [], nil)
      elsif missing_person && missing_type
        not_found(parse, "I couldn't find a crew member or certificate type matching #{quoted(phrases)}.",
          parse.person_matcher.suggestions + parse.type_matcher.suggestions, parse.leftovers.first)
      elsif missing_person
        not_found(parse, "I couldn't find a crew member named #{quoted(phrases.first(1))}.",
          parse.person_matcher.suggestions, parse.leftovers.first)
      elsif missing_type
        not_found(parse, "I couldn't find a certificate type matching #{quoted(phrases.last(1))}.",
          parse.type_matcher.suggestions, parse.leftovers.last)
      elsif intent.in?(%i[expiring expired gaps requirements]) && phrases.any?
        unmatched_filter(parse, phrases)
      end
    end

    # Words an expiry, compliance or requirements question didn't use. When they resemble a
    # person, type or project, or read like a name or code ("on 9999", "for Bob"), say what
    # couldn't be found; a stray word ("so far") is only noted, and the question answered.
    def unmatched_filter(parse, phrases)
      suggestions = Ask::ProjectMatcher.suggestions(phrases.first) + parse.person_matcher.suggestions +
        parse.type_matcher.suggestions
      return unless suggestions.any? || parse.leftovers.any? { |range| parse.question.reference?(range) }

      not_found(parse, "I couldn't find a project, crew member or certificate type matching #{quoted(phrases)}.",
        suggestions, parse.leftovers.first)
    end

    def quoted(phrases)
      phrases.any? ? Ask::Wording.either(phrases.map { |phrase| Ask::Wording.quote(phrase) }) : "that"
    end

    def ambiguous(parse, match)
      candidates = candidates_for(match.candidates, parse.question, match.range)
      { status: :ambiguous, answer: "Did you mean #{either_candidate(candidates)}?", candidates: candidates,
        crew_members: match.candidates.grep(CrewMember) }
    end

    # range: the leftover words a suggestion replaces when re-asked.
    def not_found(parse, message, suggestions, range)
      candidates = candidates_for(suggestions.uniq.first(4), parse.question, range)
      answer = candidates.any? ? "#{message} Did you mean #{either_candidate(candidates)}?" : message
      { status: :not_found, answer: answer, candidates: candidates }
    end

    def candidates_for(records, question, range)
      members = records.grep(CrewMember)
      ActiveRecord::Associations::Preloader.new(records: members, associations: :crew_role).call if members.any?

      records.map do |record|
        Ask::Candidate.new(record: record, label: base_label(record), detail: detail_for(record),
          question: range ? question.substitute(range, requery_name(record)) : question.text)
      end
    end

    # "Juan Ortiz or Juana Ortega"; names two candidates share gain their detail:
    # "Juan Ortiz (Climber · ABA Ventures) or Juan Ortiz (Skyline Tower Services)".
    def either_candidate(candidates)
      labels = candidates.map(&:label)
      Ask::Wording.either(candidates.map do |candidate|
        labels.count(candidate.label) > 1 && candidate.detail.present? ? "#{candidate.label} (#{candidate.detail})" : candidate.label
      end)
    end

    def base_label(record)
      record.respond_to?(:display_name) ? record.display_name : record.name
    end

    def requery_name(record)
      case record
      when Project then record.code.presence || record.name
      else base_label(record)
      end
    end

    def detail_for(record)
      case record
      when CrewMember then [ record.crew_role&.name, record.employer, ("inactive" unless record.active?) ].compact.join(" · ")
      when CertificateType then [ record.code, ("retired" unless record.active?) ].compact.join(" · ")
      when Project then record.active? ? "" : record.status # the label already names it
      end
    end

    # Asides about how loosely the question was read: typos and nicknames, retired types,
    # and words an answer didn't use.
    def notes(parse, answered:)
      notes = [ parse.person, parse.type, parse.project ].compact.select { |match| match.matched? && match.fuzzy && match.phrase }
        .map { |match| "Matched #{Ask::Wording.quote(match.phrase)} to #{base_label(match.record)}." }
      type = parse.type&.record
      notes << "#{type.name} is a retired certificate type." if type && parse.type.matched? && !type.active?
      if answered && parse.leftovers.any?
        notes << "Ignored #{Ask::Wording.sentence(parse.leftover_phrases.map { |phrase| Ask::Wording.quote(phrase) })}."
      end
      notes
    end
end
