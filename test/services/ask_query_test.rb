require "test_helper"

# Phase 4a acceptance: the Ask box answers at least 30 phrasings correctly (docs/PLAN.md
# "Ask box"). Each PHRASINGS row is one question and what AskQuery must make of it. Fixture
# dates are relative to Date.current (test/fixtures/certificates.yml); a row's scenario
# adds records first (see the scenario_ methods). Row keys:
#   intent, status       always checked
#   person / type / project
#                        result.crew_member / certificate_type / project: a fixture name
#                        (Symbol), a created person's full name or type's code (String), or
#                        nil for "none"
#   answer               exact String, Regexp, or a lambda run in the test returning either
#   members              result.crew_members, in order (fixture names)
#   certificates         result.certificates, in order (fixture names, or a lambda)
#   candidates           labels offered as "Did you mean", in any order
#   notes                Regexp one of result.notes must match
#   sections             Hash{section key => number of items}
class AskQueryTest < ActiveSupport::TestCase
  PHRASINGS = [
    # --- does X have Y: exact names, codes, aliases, case, possessives ---
    { q: "Does Juan Ortiz have OSHA 30?", intent: :check, status: :yes, person: :juan_ortiz, type: :osha30,
      answer: -> { "Yes. Juan Ortiz has OSHA 30 Construction, completed #{date(certificates(:juan_osha30).completed_on)}, no expiration." },
      certificates: %i[juan_osha30] },
    { q: "does juan ortiz have osha30", intent: :check, status: :yes, person: :juan_ortiz, type: :osha30 },
    { q: "Does Juan have the OSHA 30-Hour?", intent: :check, status: :yes, person: :juan_ortiz, type: :osha30 },
    { q: "Does Jon Ortiz have osha 30 hour", intent: :check, status: :yes, person: :juan_ortiz, type: :osha30 },
    { q: "DOES JUAN ORTIZ HAVE FLAGGER", intent: :check, status: :yes, person: :juan_ortiz, type: :flagger },
    { q: "Has Mari got her flagger?", intent: :check, status: :no, person: :maria_garcia, type: :flagger,
      answer: "No. Mari Garcia has no Flagger certificate on file.", certificates: [] },
    { q: "Is Juan's flagger current?", intent: :check, status: :yes, person: :juan_ortiz, type: :flagger,
      answer: -> {
        flagger = certificates(:juan_flagger)
        "Yes. Juan Ortiz has Flagger, completed #{date(flagger.completed_on)}, " \
          "but it expires in #{(flagger.expires_on - Date.current).to_i} days (#{date(flagger.expires_on)})."
      } },
    { q: "does dave miller have his CDL", intent: :check, status: :yes, person: :dave_miller, type: :cdl_a,
      answer: /\AYes\. Dave Miller has CDL Class A, completed .*, but it expires in 25 days \(/, notes: /Matched “CDL” to CDL Class A/ },
    { q: "Does David have CDL Class A?", intent: :check, status: :yes, person: :dave_miller, type: :cdl_a },
    { q: "Li's first aid?", intent: :check, status: :no, person: :li_chen, type: :first_aid,
      answer: -> { "No. Li Chen has no current First Aid/CPR/AED certificate; the last one expired #{date(certificates(:li_first_aid).expires_on)}." } },
    { q: "Does Li Chen have a climber cert?", intent: :check, status: :no, person: :li_chen, type: :climber,
      answer: "No. Li Chen has no Authorized Climber certificate on file." },
    { q: "Does Sam Price have flagger?", intent: :check, status: :yes, person: :sam_inactive, type: :flagger,
      answer: /\AYes\. Sam Price has Flagger, completed .*, but it expires in \d+ days .*\. Sam Price is marked inactive\.\z/ },
    { q: "Is Maria missing flagger?", intent: :check, status: :no, person: :maria_garcia, type: :flagger,
      answer: "Yes. Mari Garcia has no Flagger certificate on file." },
    { q: "When does Juan's flagger expire?", intent: :check, status: :yes, person: :juan_ortiz, type: :flagger,
      answer: -> {
        flagger = certificates(:juan_flagger)
        "Juan Ortiz's Flagger expires #{date(flagger.expires_on)} (in #{(flagger.expires_on - Date.current).to_i} days)."
      } },
    { q: "Has Li Chen's first aid expired?", intent: :check, status: :no, person: :li_chen, type: :first_aid,
      answer: -> { "Yes. Li Chen has no current First Aid/CPR/AED certificate; the last one expired #{date(certificates(:li_first_aid).expires_on)}." } },
    { q: "Has Juan's flagger expired?", intent: :check, status: :yes, person: :juan_ortiz, type: :flagger,
      answer: /\ANo\. Juan Ortiz has Flagger, completed .*, but it expires in \d+ days \(/ },
    { q: "Is Juan's OSHA 30 expired?", intent: :check, status: :yes, person: :juan_ortiz, type: :osha30,
      answer: /\ANo\. Juan Ortiz has OSHA 30 Construction, completed .*, no expiration\.\z/ },
    { q: "is maria's first aid expired", intent: :check, status: :no, person: :maria_garcia, type: :first_aid, answer: /\AYes\. Mari Garcia has no current/ },

    # --- misspellings and nicknames ---
    { q: "Does Jaun Ortis have OSHA 30 Construction?", intent: :check, status: :yes, person: :juan_ortiz, type: :osha30,
      notes: /Matched “Jaun Ortis” to Juan Ortiz/ },
    { q: "Does Maria Garsia have first aid?", intent: :check, status: :no, person: :maria_garcia, type: :first_aid,
      answer: -> { "No. Mari Garcia has no current First Aid/CPR/AED certificate; the last one expired #{date(certificates(:maria_first_aid).expires_on)}." } },
    { q: "does juan have flager", intent: :check, status: :yes, person: :juan_ortiz, type: :flagger, notes: /Matched “flager” to Flagger/ },
    { q: "Does Juanito Ortiz have flagger?", intent: :check, status: :yes, person: :juan_ortiz, type: :flagger,
      notes: /Matched “Juanito Ortiz” to Juan Ortiz/ },
    { q: "Does Bob Smith have flagger?", scenario: :nicknames, intent: :check, status: :no, person: "Robert Smith", type: :flagger,
      answer: "No. Robert Smith has no Flagger certificate on file." },
    { q: "Bill Turner's certs", scenario: :nicknames, intent: :list_certificates, status: :list, person: "William Turner",
      answer: "William Turner has no certificates on file." },
    { q: "does mike johnson have first aid", scenario: :nicknames, intent: :check, status: :yes, person: "Michael Johnson", type: :first_aid },
    { q: "does chuy ramos have osha 30", scenario: :nicknames, intent: :check, status: :no, person: "Jesus Ramos", type: :osha30 },

    # --- first names that are also verbs: Will, May ---
    { q: "Does Will have flagger?", scenario: :will_and_may, intent: :check, status: :no, person: "Will Turner", type: :flagger,
      answer: "No. Will Turner has no Flagger certificate on file." },
    { q: "Is May certified for first aid?", scenario: :will_and_may, intent: :check, status: :yes, person: "May Lopez", type: :first_aid },
    { q: "What does Will Turner have?", scenario: :will_and_may, intent: :list_certificates, status: :list, person: "Will Turner",
      answer: "Will Turner has no certificates on file." },
    { q: "Will Turner's certs", scenario: :will_and_may, intent: :list_certificates, status: :list, person: "Will Turner" },
    { q: "Will's certs", scenario: :will_and_may, intent: :list_certificates, status: :list, person: "Will Turner" },
    { q: "Will Juan's flagger expire soon?", scenario: :will_and_may, intent: :check, status: :yes, person: :juan_ortiz, type: :flagger },
    { q: "When will Juan's flagger expire?", scenario: :will_and_may, intent: :check, status: :yes, person: :juan_ortiz, type: :flagger },
    { q: "May I see who has CPR?", scenario: :will_and_may, intent: :list_holders, status: :list, person: nil, type: :first_aid },
    { q: "What expires in May?", scenario: :will_and_may, intent: :expiring, status: :list, person: nil },

    # --- OSHA 10 is not OSHA 30 ---
    { q: "Does Juan Ortiz have OSHA 10?", intent: :check, status: :not_found, person: :juan_ortiz, type: nil,
      answer: "I couldn't find a certificate type matching “OSHA 10”. Did you mean OSHA 30 Construction?",
      candidates: [ "OSHA 30 Construction" ] },
    { q: "Does Juan Ortiz have OSHA 10?", scenario: :osha10, intent: :check, status: :no, person: :juan_ortiz, type: "OSHA10",
      answer: "No. Juan Ortiz has no OSHA 10 Construction certificate on file." },
    { q: "does juan have osha 30", scenario: :osha10, intent: :check, status: :yes, person: :juan_ortiz, type: :osha30 },
    { q: "Does Juan have the 10-hour OSHA?", intent: :check, status: :not_found, person: :juan_ortiz, type: nil,
      answer: "I couldn't find a certificate type matching “10-hour OSHA”. Did you mean OSHA 30 Construction?",
      candidates: [ "OSHA 30 Construction" ] },
    { q: "Who has 10-hour OSHA?", intent: :list_holders, status: :not_found, type: nil,
      answer: "I couldn't find a certificate type matching “10-hour OSHA”. Did you mean OSHA 30 Construction?" },
    { q: "does juan have 10 hour osha", scenario: :osha10, intent: :check, status: :no, person: :juan_ortiz, type: "OSHA10" },
    { q: "Does Juan have the 30-hour OSHA?", intent: :check, status: :yes, person: :juan_ortiz, type: :osha30 },
    { q: "Does Juan have OSHA?", scenario: :osha10, intent: :check, status: :ambiguous, person: :juan_ortiz,
      answer: /\ADid you mean OSHA (10|30) Construction or OSHA (10|30) Construction\?\z/,
      candidates: [ "OSHA 10 Construction", "OSHA 30 Construction" ] },

    # --- ambiguous people ---
    { q: "Does Juan Orteg have OSHA 30?", scenario: :juana, intent: :check, status: :ambiguous,
      answer: /\ADid you mean (Juan Ortiz or Juana Ortega|Juana Ortega or Juan Ortiz)\?\z/,
      candidates: [ "Juan Ortiz", "Juana Ortega" ], members: nil },
    { q: "Does Juan have OSHA 30?", scenario: :juana, intent: :check, status: :yes, person: :juan_ortiz },
    { q: "Does Ortiz have flagger?", scenario: :pedro, intent: :check, status: :ambiguous, candidates: [ "Juan Ortiz", "Pedro Ortiz" ] },
    { q: "does juan smith have flagger", scenario: :nicknames, intent: :check, status: :ambiguous,
      candidates: [ "Juan Ortiz", "Robert Smith" ] },

    # --- unknown person or type ---
    { q: "Does Bob Smith have flagger?", intent: :check, status: :not_found, person: nil, type: :flagger,
      answer: "I couldn't find a crew member named “Bob Smith”." },
    { q: "Does Juan have scuba certification?", intent: :check, status: :not_found, person: :juan_ortiz, type: nil,
      answer: "I couldn't find a certificate type matching “scuba”." },
    { q: "who has scuba?", intent: :list_holders, status: :not_found, type: nil, answer: /\AI couldn't find a certificate type matching “scuba”/ },
    { q: "what does bob have", intent: :list_certificates, status: :not_found, person: nil,
      answer: "I couldn't find a crew member named “bob”." },

    # --- who has ---
    { q: "Who has flagger?", intent: :list_holders, status: :list, type: :flagger, members: %i[li_chen dave_miller juan_ortiz],
      answer: /\A3 people hold a current Flagger certificate: Li Chen \(expires .*\), Dave Miller \(expires .*\), and Juan Ortiz \(expires in \d+ days, .*\)\. Also on file for inactive crew: Sam Price\.\z/,
      sections: { current: 3, inactive: 1 } },
    { q: "who's got first aid", intent: :list_holders, status: :list, type: :first_aid, members: %i[juan_ortiz],
      answer: -> {
        "1 person holds a current First Aid/CPR/AED certificate: Juan Ortiz (expires #{date(certificates(:juan_first_aid).expires_on)}). " \
          "Expired: Li Chen (#{date(certificates(:li_first_aid).expires_on)}) and Mari Garcia (#{date(certificates(:maria_first_aid).expires_on)})."
      },
      sections: { current: 1, expired: 2 } },
    { q: "anyone with a CDL?", intent: :list_holders, status: :list, type: :cdl_a, members: %i[dave_miller] },
    { q: "list everyone with osha 30 hour", intent: :list_holders, status: :list, type: :osha30,
      members: %i[li_chen maria_garcia dave_miller juan_ortiz], sections: { current: 4, inactive: 1 } },
    { q: "who has OSHA 30 on 2417", intent: :list_holders, status: :list, type: :osha30, project: :tower_2417,
      members: %i[li_chen maria_garcia dave_miller juan_ortiz], sections: { current: 4 },
      answer: /\A4 people on 2417 · Tower 2417 Upgrade hold a current OSHA 30 Construction certificate: / },
    { q: "who has cpr", intent: :list_holders, status: :list, type: :first_aid, notes: %r{Matched “cpr” to First Aid/CPR/AED} },
    { q: "I need to know who has flagger", intent: :list_holders, status: :list, type: :flagger, members: %i[li_chen dave_miller juan_ortiz] },

    # --- who doesn't have ---
    { q: "Who doesn't have flagger?", intent: :lacking, status: :list, type: :flagger, members: %i[maria_garcia],
      answer: "1 active crew member doesn't hold a current Flagger certificate: Mari Garcia (none on file).",
      certificates: [], sections: { lacking: 1 } },
    { q: "Who does not have flagger?", intent: :lacking, status: :list, type: :flagger, members: %i[maria_garcia] },
    { q: "who doesn't have first aid", intent: :lacking, status: :list, type: :first_aid, members: %i[li_chen maria_garcia dave_miller],
      certificates: %i[li_first_aid maria_first_aid],
      answer: -> {
        "3 active crew members don't hold a current First Aid/CPR/AED certificate: Li Chen (expired #{date(certificates(:li_first_aid).expires_on)}), " \
          "Mari Garcia (expired #{date(certificates(:maria_first_aid).expires_on)}), and Dave Miller (none on file)."
      } },
    { q: "anyone without a CDL?", intent: :lacking, status: :list, type: :cdl_a, members: %i[li_chen maria_garcia juan_ortiz] },
    { q: "who doesn't have flagger on 2417", intent: :lacking, status: :list, type: :flagger, project: :tower_2417, members: %i[maria_garcia],
      answer: "1 person on 2417 · Tower 2417 Upgrade doesn't hold a current Flagger certificate: Mari Garcia (none on file)." },
    { q: "who doesn't have scuba", intent: :lacking, status: :not_found, type: nil, answer: "I couldn't find a certificate type matching “scuba”." },
    { q: "who needs flagger on 2417", intent: :gaps, status: :list, type: :flagger, project: :tower_2417, members: %i[maria_garcia],
      answer: "2417 · Tower 2417 Upgrade has 1 Flagger gap (1 missing): Mari Garcia (missing)." },
    { q: "Who needs flagger on 2417?", intent: :gaps, status: :list, type: :flagger, project: :tower_2417, members: %i[maria_garcia] },

    # --- what does X have ---
    { q: "What does Juan Ortiz have?", intent: :list_certificates, status: :list, person: :juan_ortiz,
      certificates: %i[juan_osha30 juan_flagger juan_first_aid juan_climber],
      answer: /\AJuan Ortiz has 4 certificates on file: OSHA 30 Construction \(no expiration\), Flagger \(expires in \d+ days, / },
    { q: "Maria's certs", intent: :list_certificates, status: :list, person: :maria_garcia,
      certificates: %i[maria_osha30 maria_first_aid],
      answer: -> { "Mari Garcia has 2 certificates on file: OSHA 30 Construction (no expiration) and First Aid/CPR/AED (expired #{date(certificates(:maria_first_aid).expires_on)})." } },
    { q: "show me li chen", intent: :list_certificates, status: :list, person: :li_chen, certificates: %i[li_osha30 li_flagger li_first_aid] },
    { q: "what certificates does dave have", intent: :list_certificates, status: :list, person: :dave_miller,
      certificates: %i[dave_osha30 dave_flagger dave_cdl_a] },
    { q: "What does Sam have?", intent: :list_certificates, status: :list, person: :sam_inactive, answer: /Sam Price is marked inactive\.\z/ },

    # --- expiring ---
    { q: "What's expiring?", intent: :expiring, status: :list, certificates: %i[juan_flagger dave_cdl_a],
      answer: -> {
        "2 certificates expire in the next 30 days (by #{date(Date.current + 30)}): Juan Ortiz's Flagger on " \
          "#{date(certificates(:juan_flagger).expires_on)} and Dave Miller's CDL Class A on #{date(certificates(:dave_cdl_a).expires_on)}."
      } },
    { q: "What expires in 60 days?", intent: :expiring, status: :list, certificates: %i[juan_flagger dave_cdl_a juan_first_aid],
      answer: /\A3 certificates expire in the next 60 days / },
    { q: "who expires in the next 2 weeks", intent: :expiring, status: :list, certificates: %i[juan_flagger],
      answer: -> { /\A1 certificate expires in the next 2 weeks \(by #{Regexp.escape(date(Date.current + 14))}\): Juan Ortiz's Flagger on / } },
    { q: "expiring this month", intent: :expiring, status: :list,
      certificates: -> { %i[juan_flagger dave_cdl_a juan_first_aid].select { |name| certificates(name).expires_on <= Date.current.end_of_month } },
      answer: -> { /expire(s)? this month \(by #{Regexp.escape(date(Date.current.end_of_month))}\)/ } },
    { q: "Any flagger certs expiring in the next 90 days?", intent: :expiring, status: :list, type: :flagger, certificates: %i[juan_flagger],
      answer: /\A1 Flagger certificate expires in the next 90 days \(by .*\): Juan Ortiz on / },
    { q: "what's expiring on 2417", intent: :expiring, status: :list, project: :tower_2417, certificates: %i[juan_flagger dave_cdl_a],
      answer: /\A2 certificates on 2417 · Tower 2417 Upgrade expire in the next 30 days / },
    { q: "What expires for Juan in the next 90 days?", intent: :expiring, status: :list, person: :juan_ortiz,
      certificates: %i[juan_flagger juan_first_aid], answer: /\A2 certificates held by Juan Ortiz expire in the next 90 days .*: Flagger on .* and First Aid/ },
    { q: "What expires in a week?", intent: :expiring, status: :list, certificates: [],
      answer: -> { "No certificates expire in the next week (by #{date(Date.current + 7)})." } },
    { q: "What expires within a year?", intent: :expiring, status: :list, certificates: %i[juan_flagger dave_cdl_a juan_first_aid],
      answer: -> { /\A3 certificates expire in the next year \(by #{Regexp.escape(date(Date.current.advance(years: 1)))}\): / } },
    { q: "What expires in forty-five days?", intent: :expiring, status: :list, certificates: %i[juan_flagger dave_cdl_a],
      answer: -> { /\A2 certificates expire in the next 45 days \(by #{Regexp.escape(date(Date.current + 45))}\): / } },

    # --- already expired ---
    { q: "Which certificates have expired?", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid],
      answer: -> {
        "2 certificates have expired: Mari Garcia's First Aid/CPR/AED on #{date(certificates(:maria_first_aid).expires_on)} and " \
          "Li Chen's First Aid/CPR/AED on #{date(certificates(:li_first_aid).expires_on)}."
      },
      sections: { expired: 2 } },
    { q: "What has expired?", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "Who has expired certificates?", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "Which certs expired?", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "what's past due", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "who has an expired first aid", intent: :expired, status: :list, type: :first_aid, certificates: %i[maria_first_aid li_first_aid],
      answer: /\A2 First Aid\/CPR\/AED certificates have expired: Mari Garcia on .* and Li Chen on / },
    { q: "whose first aid is expired", intent: :expired, status: :list, type: :first_aid, certificates: %i[maria_first_aid li_first_aid] },
    { q: "what expired recently", intent: :expired, status: :list, certificates: %i[maria_first_aid],
      answer: -> {
        "1 certificate expired in the last 30 days (since #{date(Date.current - 30)}): Mari Garcia's First Aid/CPR/AED on " \
          "#{date(certificates(:maria_first_aid).expires_on)}."
      } },
    { q: "what expired last month", intent: :expired, status: :list, certificates: %i[maria_first_aid],
      answer: -> { /\A1 certificate expired in the last month \(since #{Regexp.escape(date(Date.current.advance(months: -1)))}\): / } },
    { q: "What lapsed in the last 2 years?", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "What's expired on 2417?", intent: :expired, status: :list, project: :tower_2417, certificates: %i[maria_first_aid li_first_aid],
      answer: /\A2 certificates on 2417 · Tower 2417 Upgrade have expired: / },
    { q: "Has anything of Juan's expired?", intent: :expired, status: :list, person: :juan_ortiz, certificates: [],
      answer: "No certificates held by Juan Ortiz have expired." },
    { q: "who has a lapsed first aid", intent: :expired, status: :list, type: :first_aid, certificates: %i[maria_first_aid li_first_aid] },
    { q: "any lapses?", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "lapses on 2417", intent: :expired, status: :list, project: :tower_2417, certificates: %i[maria_first_aid li_first_aid] },
    { q: "what's out of date", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid],
      answer: /\A2 certificates have expired: Mari Garcia's First Aid/ },
    { q: "Which certificates are out of date?", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "who is out of date on first aid", intent: :expired, status: :list, type: :first_aid, certificates: %i[maria_first_aid li_first_aid] },
    { q: "which certificates are no longer valid", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "is anything no longer valid?", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid] },
    { q: "Is Juan's first aid out of date?", intent: :check, status: :yes, person: :juan_ortiz, type: :first_aid,
      answer: /\ANo\. Juan Ortiz has First Aid\/CPR\/AED, completed / },
    { q: "Is Mari's first aid no longer valid?", intent: :check, status: :no, person: :maria_garcia, type: :first_aid,
      answer: /\AYes\. Mari Garcia has no current First Aid/ },
    { q: "what has expired so far", intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid], candidates: [],
      notes: /\AIgnored “so far”\.\z/ },
    { q: "which certs lapse next month", intent: :expiring, status: :list, certificates: %i[juan_flagger dave_cdl_a] },
    { q: "What will lapse soon?", intent: :expiring, status: :list, certificates: %i[juan_flagger dave_cdl_a] },

    # --- missing / gaps ---
    { q: "What's missing on 2417?", intent: :gaps, status: :list, project: :tower_2417,
      answer: /\A2417 · Tower 2417 Upgrade has 5 gaps \(2 expired, 3 missing\): Li Chen: First Aid\/CPR\/AED \(expired .*\), Authorized Climber \(missing\); Mari Garcia: Flagger \(missing\), First Aid\/CPR\/AED \(expired .*\); Dave Miller: First Aid\/CPR\/AED \(missing\)\.\z/,
      members: %i[li_chen maria_garcia dave_miller] },
    { q: "who is missing certs on Tower 2417 Upgrade", intent: :gaps, status: :list, project: :tower_2417, answer: /has 5 gaps/ },
    { q: "Is 2417 compliant?", intent: :gaps, status: :list, project: :tower_2417, answer: /has 5 gaps/ },
    { q: "missing", intent: :gaps, status: :list, project: nil, answer: /\A5 gaps on 1 active project \(2 expired, 3 missing\)\. 2417 · Tower 2417 Upgrade: / },
    { q: "What is Maria missing?", intent: :gaps, status: :list, person: :maria_garcia, members: %i[maria_garcia],
      answer: /\AMari Garcia has 2 gaps \(1 expired, 1 missing\) on 1 active project\. 2417 · Tower 2417 Upgrade: Flagger \(missing\) and First Aid/ },
    { q: "who's missing flagger on 2417", intent: :gaps, status: :list, type: :flagger, project: :tower_2417, members: %i[maria_garcia],
      answer: "2417 · Tower 2417 Upgrade has 1 Flagger gap (1 missing): Mari Garcia (missing)." },
    { q: "Who is missing what on 2417?", intent: :gaps, status: :list, project: :tower_2417, answer: /has 5 gaps/ },
    { q: "gaps on 2417", intent: :gaps, status: :list, project: :tower_2417, answer: /has 5 gaps/ },
    { q: "what's missing on 9999", intent: :gaps, status: :not_found, project: nil,
      answer: "I couldn't find a project, crew member or certificate type matching “9999”.", candidates: [] },
    { q: "what's missing on 2471", intent: :gaps, status: :not_found, project: nil,
      answer: "I couldn't find a project, crew member or certificate type matching “2471”. Did you mean 2417 · Tower 2417 Upgrade?",
      candidates: [ "2417 · Tower 2417 Upgrade" ] },
    { q: "What's expiring for Bob?", intent: :expiring, status: :not_found, candidates: [],
      answer: "I couldn't find a project, crew member or certificate type matching “Bob”." },

    # --- what a project requires ---
    { q: "What's required on 2417?", intent: :requirements, status: :list, project: :tower_2417, type: nil,
      answer: "2417 · Tower 2417 Upgrade requires 5 certificate types: OSHA 30 Construction, Flagger, First Aid/CPR/AED, " \
        "Authorized Climber (Climber role), and CDL Class A (Operator role). 3 of 4 assigned crew are missing at least one: " \
        "Li Chen, Mari Garcia, and Dave Miller.",
      members: %i[li_chen maria_garcia dave_miller], certificates: %i[li_first_aid maria_first_aid], sections: { requirements: 5, gaps: 5 } },
    { q: "what does project 2417 require", intent: :requirements, status: :list, project: :tower_2417, answer: /\A2417 · Tower 2417 Upgrade requires 5 certificate types: / },
    { q: "requirements for 2417", intent: :requirements, status: :list, project: :tower_2417, answer: /3 of 4 assigned crew are missing at least one/ },
    { q: "what does 2417 need?", intent: :requirements, status: :list, project: :tower_2417 },
    { q: "Is flagger required on 2417?", intent: :requirements, status: :list, project: :tower_2417, type: :flagger, members: %i[maria_garcia],
      answer: "2417 · Tower 2417 Upgrade requires Flagger for everyone on the crew. 1 of 4 on the crew who need it is missing it: Mari Garcia (missing).",
      sections: { requirements: 1, gaps: 1 } },
    { q: "Does 2417 require a CDL?", intent: :requirements, status: :list, project: :tower_2417, type: :cdl_a, members: [],
      answer: "2417 · Tower 2417 Upgrade requires CDL Class A for the Operator role. Everyone on the crew who needs it (1 person) holds a current one.",
      sections: { requirements: 1 } },
    { q: "What do I need for 2417?", intent: :requirements, status: :list, project: :tower_2417 },
    { q: "What is required on 2417 for Juan?", intent: :gaps, status: :list, project: :tower_2417, person: :juan_ortiz,
      answer: "Juan Ortiz has no gaps on 2417 · Tower 2417 Upgrade." },

    # --- flagged for review (Phase 3b): automatic checks flagged Juan's Flagger (not found by issuer), Li's
    # expired first aid (its QR code's details don't match) and Dave's CDL (a lookalike link). Never omit a
    # certificate unless it is verified fake (owner, Nov 4, 2026): each still counts by its dates, and says so ---
    { q: "Does Juan have flagger?", scenario: :flagged, intent: :check, status: :yes, person: :juan_ortiz, type: :flagger,
      certificates: %i[juan_flagger],
      answer: -> {
        flagger = certificates(:juan_flagger)
        "Yes. Juan Ortiz has Flagger, completed #{date(flagger.completed_on)}, but it expires in " \
          "#{(flagger.expires_on - Date.current).to_i} days (#{date(flagger.expires_on)}). " \
          "It's flagged for review (not found by issuer) but still counts until someone checks it with the issuer."
      } },
    { q: "Is Juan missing flagger?", scenario: :flagged, intent: :check, status: :yes, person: :juan_ortiz, type: :flagger,
      answer: /\ANo\. Juan Ortiz has Flagger, .* It's flagged for review \(not found by issuer\) but still counts / },
    { q: "Has Juan's flagger expired?", scenario: :flagged, intent: :check, status: :yes, person: :juan_ortiz, type: :flagger,
      answer: /\ANo\. Juan Ortiz has Flagger, completed .*, but it expires in \d+ days \(.*\)\. It's flagged for review / },
    { q: "Has Li Chen's first aid expired?", scenario: :flagged, intent: :check, status: :no, person: :li_chen, type: :first_aid,
      answer: -> {
        "Yes. Li Chen has no current First Aid/CPR/AED certificate; the last one expired " \
          "#{date(certificates(:li_first_aid).expires_on)}. It's also flagged for review (doesn't match issuer)."
      } },
    { q: "When does Juan's flagger expire?", scenario: :flagged, intent: :check, status: :yes, person: :juan_ortiz, type: :flagger,
      answer: -> {
        flagger = certificates(:juan_flagger)
        "Juan Ortiz's Flagger expires #{date(flagger.expires_on)} (in #{(flagger.expires_on - Date.current).to_i} days). " \
          "It's flagged for review (not found by issuer) but still counts until someone checks it with the issuer."
      } },
    { q: "Does Dave have his CDL?", scenario: :flagged, intent: :check, status: :yes, person: :dave_miller, type: :cdl_a,
      answer: /\AYes\. Dave Miller has CDL Class A, .*\. It's flagged for review \(suspicious link\) but still counts until someone checks it with the issuer\.\z/ },
    { q: "Who has flagger?", scenario: :flagged, intent: :list_holders, status: :list, type: :flagger, members: %i[li_chen dave_miller juan_ortiz],
      answer: /\A3 people hold a current Flagger certificate: Li Chen \(expires [^;]*\), Dave Miller \(expires [^;]*\), and Juan Ortiz \(expires in \d+ days, [^;]*; flagged for review: not found by issuer\)\. Also on file for inactive crew: Sam Price\.\z/,
      sections: { current: 3, inactive: 1 } },
    { q: "Who has a valid flagger card?", scenario: :flagged, intent: :list_holders, status: :list, type: :flagger,
      members: %i[li_chen dave_miller juan_ortiz], sections: { current: 3, inactive: 1 },
      answer: /, and Juan Ortiz \(expires in \d+ days, [^;]*; flagged for review: not found by issuer\)\./ },
    { q: "who's got first aid", scenario: :flagged, intent: :list_holders, status: :list, type: :first_aid, members: %i[juan_ortiz],
      answer: /\. Expired: Li Chen \([^;]*; flagged for review: doesn't match issuer\) and Mari Garcia \([^;]*\)\.\z/ },
    { q: "Who doesn't have flagger?", scenario: :flagged, intent: :lacking, status: :list, type: :flagger, members: %i[maria_garcia],
      certificates: [], answer: "1 active crew member doesn't hold a current Flagger certificate: Mari Garcia (none on file)." },
    { q: "who doesn't have first aid", scenario: :flagged, intent: :lacking, status: :list, type: :first_aid,
      members: %i[li_chen maria_garcia dave_miller],
      answer: -> {
        "3 active crew members don't hold a current First Aid/CPR/AED certificate: Li Chen (expired " \
          "#{date(certificates(:li_first_aid).expires_on)}; flagged for review: doesn't match issuer), " \
          "Mari Garcia (expired #{date(certificates(:maria_first_aid).expires_on)}), and Dave Miller (none on file)."
      } },
    { q: "What's missing on 2417?", scenario: :flagged, intent: :gaps, status: :list, project: :tower_2417,
      members: %i[li_chen maria_garcia dave_miller],
      answer: -> {
        "2417 · Tower 2417 Upgrade has 5 gaps (2 expired, 3 missing): " \
          "Li Chen: First Aid/CPR/AED (expired #{date(certificates(:li_first_aid).expires_on)}; flagged for review: doesn't match issuer), " \
          "Authorized Climber (missing); Mari Garcia: Flagger (missing), First Aid/CPR/AED (expired " \
          "#{date(certificates(:maria_first_aid).expires_on)}); Dave Miller: First Aid/CPR/AED (missing)."
      } },
    { q: "who needs flagger on 2417", scenario: :flagged, intent: :gaps, status: :list, type: :flagger, project: :tower_2417,
      members: %i[maria_garcia], answer: "2417 · Tower 2417 Upgrade has 1 Flagger gap (1 missing): Mari Garcia (missing)." },
    { q: "What's expiring?", scenario: :flagged, intent: :expiring, status: :list, certificates: %i[juan_flagger dave_cdl_a],
      answer: -> {
        "2 certificates expire in the next 30 days (by #{date(Date.current + 30)}): Juan Ortiz's Flagger on " \
          "#{date(certificates(:juan_flagger).expires_on)} (flagged for review: not found by issuer) and " \
          "Dave Miller's CDL Class A on #{date(certificates(:dave_cdl_a).expires_on)} (flagged for review: suspicious link)."
      } },
    { q: "Which certificates have expired?", scenario: :flagged, intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid],
      answer: /\A2 certificates have expired: Mari Garcia's First Aid\/CPR\/AED on [^(]* and Li Chen's First Aid\/CPR\/AED on .* \(flagged for review: doesn't match issuer\)\.\z/ },
    { q: "What does Juan Ortiz have?", scenario: :flagged, intent: :list_certificates, status: :list, person: :juan_ortiz,
      answer: /, Flagger \(expires in \d+ days, [^;]*; flagged for review: not found by issuer\), First Aid/ },

    # --- confirmed fake (Phase 3b): a person checked with the issuer and recorded Juan's Flagger as not found
    # and Li's expired first aid as not matching. Only these count as not valid ---
    { q: "Does Juan have flagger?", scenario: :fake, intent: :check, status: :no, person: :juan_ortiz, type: :flagger,
      certificates: %i[juan_flagger],
      answer: "No. Juan Ortiz's Flagger certificate is confirmed fake (not found by issuer), so it doesn't count." },
    { q: "Is Juan missing flagger?", scenario: :fake, intent: :check, status: :no, person: :juan_ortiz, type: :flagger,
      answer: "Yes. Juan Ortiz's Flagger certificate is confirmed fake (not found by issuer), so it doesn't count." },
    { q: "Has Juan's flagger expired?", scenario: :fake, intent: :check, status: :no, person: :juan_ortiz, type: :flagger,
      answer: -> {
        flagger = certificates(:juan_flagger)
        "No. Juan Ortiz's Flagger expires #{date(flagger.expires_on)} (in #{(flagger.expires_on - Date.current).to_i} days), " \
          "but it is confirmed fake (not found by issuer), so it doesn't count."
      } },
    { q: "Has Li Chen's first aid expired?", scenario: :fake, intent: :check, status: :no, person: :li_chen, type: :first_aid,
      answer: -> {
        "Yes. Li Chen's First Aid/CPR/AED expired #{date(certificates(:li_first_aid).expires_on)}, " \
          "but it is confirmed fake (doesn't match issuer), so it doesn't count."
      } },
    { q: "When does Juan's flagger expire?", scenario: :fake, intent: :check, status: :no, person: :juan_ortiz, type: :flagger,
      answer: -> {
        flagger = certificates(:juan_flagger)
        "Juan Ortiz's Flagger expires #{date(flagger.expires_on)} (in #{(flagger.expires_on - Date.current).to_i} days), " \
          "but it is confirmed fake (not found by issuer), so it doesn't count."
      } },
    { q: "Who has flagger?", scenario: :fake, intent: :list_holders, status: :list, type: :flagger, members: %i[li_chen dave_miller],
      answer: /\A2 people hold a current Flagger certificate: Li Chen \(expires [^;]*\) and Dave Miller \(expires [^;]*\)\. Confirmed fake, so not counted: Juan Ortiz \(not found by issuer\)\. Also on file for inactive crew: Sam Price\.\z/,
      sections: { current: 2, fake: 1, inactive: 1 } },
    { q: "Who doesn't have flagger?", scenario: :fake, intent: :lacking, status: :list, type: :flagger,
      members: %i[maria_garcia juan_ortiz], certificates: %i[juan_flagger],
      answer: "2 active crew members don't hold a current Flagger certificate: Mari Garcia (none on file) and " \
        "Juan Ortiz (confirmed fake: not found by issuer)." },
    { q: "What's missing on 2417?", scenario: :fake, intent: :gaps, status: :list, project: :tower_2417,
      members: %i[li_chen maria_garcia dave_miller juan_ortiz],
      answer: -> {
        "2417 · Tower 2417 Upgrade has 6 gaps (2 confirmed fake, 1 expired, 3 missing): " \
          "Li Chen: First Aid/CPR/AED (confirmed fake: doesn't match issuer), Authorized Climber (missing); " \
          "Mari Garcia: Flagger (missing), First Aid/CPR/AED (expired #{date(certificates(:maria_first_aid).expires_on)}); " \
          "Dave Miller: First Aid/CPR/AED (missing); Juan Ortiz: Flagger (confirmed fake: not found by issuer)."
      } },
    { q: "who needs flagger on 2417", scenario: :fake, intent: :gaps, status: :list, type: :flagger, project: :tower_2417,
      members: %i[maria_garcia juan_ortiz],
      answer: "2417 · Tower 2417 Upgrade has 2 Flagger gaps (1 confirmed fake, 1 missing): Mari Garcia (missing); " \
        "Juan Ortiz (confirmed fake: not found by issuer)." },
    { q: "What's expiring?", scenario: :fake, intent: :expiring, status: :list, certificates: %i[juan_flagger dave_cdl_a],
      answer: -> {
        "2 certificates expire in the next 30 days (by #{date(Date.current + 30)}): Juan Ortiz's Flagger on " \
          "#{date(certificates(:juan_flagger).expires_on)} (confirmed fake: not found by issuer) and " \
          "Dave Miller's CDL Class A on #{date(certificates(:dave_cdl_a).expires_on)}."
      } },
    { q: "Which certificates have expired?", scenario: :fake, intent: :expired, status: :list, certificates: %i[maria_first_aid li_first_aid],
      answer: /and Li Chen's First Aid\/CPR\/AED on .* \(confirmed fake: doesn't match issuer\)\.\z/ },
    { q: "What does Juan Ortiz have?", scenario: :fake, intent: :list_certificates, status: :list, person: :juan_ortiz,
      answer: /, Flagger \(expires in \d+ days, [^;]*; confirmed fake: not found by issuer\), First Aid/ },

    # --- not a question we can answer ---
    { q: "asdf qwerty", intent: :unknown, status: :unknown, answer: "I'm not sure what you're asking. #{AskQuery::HELP}" },
    { q: "hello there", intent: :unknown, status: :unknown, answer: /\AI'm not sure what you're asking\./ },
    { q: "", intent: :unknown, status: :unknown, answer: AskQuery::HELP }
  ].freeze

  setup do
    @viewer = users(:viewer)
  end

  PHRASINGS.each_with_index do |row, index|
    test "phrasing #{index + 1}: #{row[:q].inspect}#{" (#{row[:scenario]})" if row[:scenario]}" do
      send(:"scenario_#{row[:scenario]}") if row[:scenario]
      result = ask(row[:q])
      context = "#{row[:q].inspect} -> #{result.intent}/#{result.status}: #{result.answer}"

      assert_equal row[:intent], result.intent, context
      assert_equal row[:status], result.status, context
      assert_record person(row[:person]), result.crew_member, context if row.key?(:person)
      assert_record certificate_type(row[:type]), result.certificate_type, context if row.key?(:type)
      assert_record row[:project] && projects(row[:project]), result.project, context if row.key?(:project)
      assert_answer row[:answer], result.answer, context if row.key?(:answer)
      if row[:members]
        assert_equal row[:members].map { |name| crew_members(name).id }, result.crew_members.map(&:id), context
      end
      if row[:certificates]
        names = row[:certificates].is_a?(Proc) ? instance_exec(&row[:certificates]) : row[:certificates]
        assert_equal names.map { |name| certificates(name).id }, result.certificates.map(&:id), context
      end
      assert_equal row[:candidates].sort, result.candidates.map(&:label).sort, context if row[:candidates]
      assert result.notes.any? { |note| note.match?(row[:notes]) }, "#{context}\nnotes: #{result.notes.inspect}" if row[:notes]
      if row[:sections]
        assert_equal row[:sections], result.sections.to_h { |section| [ section.key, section.items.size ] }, context
      end
    end
  end

  test "the phrasing table covers at least 30 questions" do
    assert_operator PHRASINGS.size, :>=, 30
  end

  # --- result shape ---

  test "a check names the certificate as evidence" do
    result = ask("Does Juan Ortiz have flagger?")

    item = result.evidence.sole
    assert_equal crew_members(:juan_ortiz), item.crew_member
    assert_equal certificate_types(:flagger), item.certificate_type
    assert_equal certificates(:juan_flagger), item.certificate
    assert_equal "expiring", item.status
    assert_equal certificates(:juan_flagger).expires_on, item.expires_on
    assert result.answered?
    assert_equal "Does Juan Ortiz have flagger?", result.question
  end

  test "a missing certificate is evidence with no certificate" do
    item = ask("Does Mari have flagger?").evidence.sole

    assert_nil item.certificate
    assert_equal "missing", item.status
    assert_equal crew_members(:maria_garcia), item.crew_member
  end

  test "gaps carry their project and the expired certificate" do
    result = ask("What's missing on 2417?")

    section = result.sections.sole
    assert_equal "2417 · Tower 2417 Upgrade", section.title
    expired = section.items.find { |item| item.crew_member == crew_members(:maria_garcia) && item.status == "expired" }
    assert_equal certificates(:maria_first_aid), expired.certificate
    assert_equal projects(:tower_2417), expired.project
    assert_equal %w[expired missing], section.items.map(&:status).uniq.sort
  end

  test "an expiring answer carries its window" do
    result = ask("What expires in the next 3 months?")

    assert_equal Date.current, result.window.from
    assert_equal Date.current.advance(months: 3), result.window.to
    assert_equal "in the next 3 months", result.window.label
    assert_nil ask("Who has flagger?").window
  end

  test "an expired answer carries a past window, and none when it asks about all time" do
    result = ask("What expired in the last 60 days?")

    assert_equal :expired, result.intent
    assert_equal Date.current - 60, result.window.from
    assert_equal Date.current - 1, result.window.to
    assert result.window.past
    assert_nil ask("What has expired?").window
  end

  test "a forward window keeps 'expired' an expiring question" do
    assert_equal :expiring, ask("What will have expired by next month?").intent
  end

  test "inactive crew are left out of the expired and lacking lists" do
    certificates(:sam_flagger).update_columns(expires_on: Date.current - 3)

    assert_not_includes ask("What has expired?").crew_members, crew_members(:sam_inactive)
    assert_not_includes ask("Who doesn't have flagger?").crew_members, crew_members(:sam_inactive)
  end

  test "everyone holding the type reads as good news" do
    assert_equal "Everyone on the active crew holds a current OSHA 30 Construction certificate.", ask("Who doesn't have OSHA 30?").answer
  end

  test "gaps leave out inactive crew and closed projects" do
    result = ask("missing")

    assert_not_includes result.crew_members, crew_members(:sam_inactive)
    assert_equal [ projects(:tower_2417) ], result.evidence.map(&:project).uniq
  end

  test "a closed project can still be asked about by code" do
    result = ask("What's missing on 2390?")

    assert_equal :gaps, result.intent
    assert_equal projects(:closed_2390), result.project
    assert_match(/2390 · Rooftop 2390 is closed\./, result.answer)
  end

  test "no gaps reads as good news" do
    project = Project.create!(name: "Empty Site", code: "3001", status: :active)

    result = ask("What's missing on 3001?")

    assert_equal project, result.project
    assert_equal "No gaps on 3001 · Empty Site: everyone on the crew holds a current certificate for each type they need.", result.answer
    assert_empty result.sections
  end

  test "nothing expiring says so" do
    result = ask("What expires today?")

    assert_equal :list, result.status
    assert_equal "No certificates expire today (#{date(Date.current)}).", result.answer
  end

  test "an expired-only holder list says nobody holds a current one" do
    certificates(:juan_first_aid).destroy!

    assert_match(/\ANobody holds a current First Aid\/CPR\/AED certificate\. Expired: /, ask("Who has first aid?").answer)
  end

  test "requirements name each type's roles, notes and how the crew stands" do
    result = ask("What's required on 2417?")

    requirements = result.sections.find { |section| section.key == :requirements }.items
    assert_equal %i[osha30 flagger first_aid climber cdl_a].map { |name| certificate_types(name) }, requirements.map(&:certificate_type)
    climber = requirements.find { |requirement| requirement.certificate_type == certificate_types(:climber) }
    assert_equal [ crew_roles(:climber) ], climber.crew_roles
    assert_equal [ "Anyone working above 6 ft on the tower." ], climber.notes
    assert_equal [ 2, 1 ], [ climber.needed, climber.missing ] # Juan, and Li as a climber on this project
    first_aid = requirements.find { |requirement| requirement.certificate_type == certificate_types(:first_aid) }
    assert first_aid.everyone?
    assert_equal [ 4, 3 ], [ first_aid.needed, first_aid.missing ]
    gaps = result.sections.find { |section| section.key == :gaps }
    assert_equal "Missing or expired", gaps.title
    assert_equal [ projects(:tower_2417) ], gaps.items.map(&:project).uniq
    assert_nil result.window
  end

  test "requirements count a confirmed fake certificate as a gap and say why" do
    scenario_fake

    result = ask("What's required on 2417?")
    flagger = result.sections.find { |section| section.key == :requirements }.items
      .find { |requirement| requirement.certificate_type == certificate_types(:flagger) }
    gaps = result.sections.find { |section| section.key == :gaps }

    assert_equal [ 4, 2 ], [ flagger.needed, flagger.missing ]
    assert_equal "Missing, expired or confirmed fake", gaps.title
    assert_includes gaps.items.map(&:status), "fake"
    assert_match(/4 of 4 assigned crew are missing at least one: /, result.answer)
    assert_equal "2417 · Tower 2417 Upgrade requires Flagger for everyone on the crew. 2 of 4 on the crew who need it are missing it: " \
      "Mari Garcia (missing) and Juan Ortiz (confirmed fake: not found by issuer).", ask("Is flagger required on 2417?").answer
  end

  test "requirements still count a certificate that is only flagged for review" do
    scenario_flagged

    result = ask("What's required on 2417?")
    flagger = result.sections.find { |section| section.key == :requirements }.items
      .find { |requirement| requirement.certificate_type == certificate_types(:flagger) }
    gaps = result.sections.find { |section| section.key == :gaps }

    assert_equal [ 4, 1 ], [ flagger.needed, flagger.missing ]
    assert_equal "Missing or expired", gaps.title
    assert_not_includes gaps.items.map(&:certificate), certificates(:juan_flagger)
    assert_match(/3 of 4 assigned crew are missing at least one: Li Chen, Mari Garcia, and Dave Miller\.\z/, result.answer)
    assert_equal "2417 · Tower 2417 Upgrade requires Flagger for everyone on the crew. 1 of 4 on the crew who need it is missing it: " \
      "Mari Garcia (missing).", ask("Is flagger required on 2417?").answer
    assert_match(/missing it: Li Chen \(expired [^;]*; flagged for review: doesn't match issuer\), Mari Garcia \(expired [^;]*\), and Dave Miller \(missing\)\.\z/,
      ask("Is first aid required on 2417?").answer)
  end

  test "a confirmed fake certificate's evidence row carries the fake status" do
    scenario_fake

    item = ask("Does Juan have flagger?").evidence.sole
    assert_equal "fake", item.status
    assert_equal certificates(:juan_flagger), item.certificate
    assert_equal %w[fake], ask("Who has flagger?").sections.find { |section| section.key == :fake }.items.map(&:status)
    assert_equal "Confirmed fake", ask("Who has flagger?").sections.find { |section| section.key == :fake }.title
  end

  test "a certificate flagged for review keeps its date status as evidence, with the certificate for its marker" do
    scenario_flagged

    item = ask("Does Juan have flagger?").evidence.sole
    assert_equal "expiring", item.status
    assert_equal certificates(:juan_flagger), item.certificate
    assert item.certificate.authenticity_flagged_for_review?

    holders = ask("Who has flagger?")
    current = holders.sections.find { |section| section.key == :current }
    juan = current.items.find { |row| row.certificate == certificates(:juan_flagger) }
    assert_equal "expiring", juan.status
    assert_nil holders.sections.find { |section| section.key == :fake }
  end

  test "a suspicious result recorded by a person is not confirmed fake" do
    certificates(:juan_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:suspicious],
      authenticity_method: Authenticity::PERSON_METHOD)

    result = ask("Does Juan have flagger?")

    assert_equal :yes, result.status
    assert_equal "expiring", result.evidence.sole.status
    assert_match(/\. It's flagged for review \(suspicious link\) but still counts until someone checks it with the issuer\.\z/, result.answer)
    assert_includes ask("Who has flagger?").crew_members, crew_members(:juan_ortiz)
    assert_not_includes ask("Who doesn't have flagger?").crew_members, crew_members(:juan_ortiz)
    assert_no_match(/fake/, ask("What's missing on 2417?").answer)
  end

  test "a person's verified result reads like an unchecked one" do
    certificates(:juan_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:verified],
      authenticity_method: Authenticity::PERSON_METHOD)

    assert_no_match(/flagged|fake/, ask("Does Juan have flagger?").answer)
    assert_no_match(/flagged|fake/, ask("Who has flagger?").answer)
  end

  test "a type required of everyone and of a role is required of everyone" do
    ProjectRequirement.create!(project: projects(:tower_2417), certificate_type: certificate_types(:flagger), crew_role: crew_roles(:climber))
    ProjectRequirement.create!(project: projects(:tower_2417), certificate_type: certificate_types(:cdl_a), crew_role: crew_roles(:foreman))

    answer = ask("What's required on 2417?").answer

    assert_match(/OSHA 30 Construction, Flagger, First Aid/, answer)
    assert_match(/CDL Class A \(Foreman and Operator roles\)\./, answer)
  end

  test "requirements without crew, without gaps and without requirements" do
    empty = Project.create!(name: "Empty Site", code: "3001", status: :active)
    assert_equal "3001 · Empty Site has no certificate requirements yet.", ask("What's required on 3001?").answer
    assert_empty ask("What's required on 3001?").sections

    empty.project_requirements.create!(certificate_type: certificate_types(:osha30))
    assert_equal "3001 · Empty Site requires 1 certificate type: OSHA 30 Construction. Nobody is on the crew.", ask("What's required on 3001?").answer

    empty.project_assignments.create!(crew_member: crew_members(:juan_ortiz))
    result = ask("requirements for 3001")
    assert_equal "3001 · Empty Site requires 1 certificate type: OSHA 30 Construction. " \
      "Everyone on the crew (1 person) holds a current certificate for each type they need.", result.answer
    assert_equal [ :requirements ], result.sections.map(&:key)

    assert_equal "3001 · Empty Site requires OSHA 30 Construction for everyone on the crew. " \
      "Everyone on the crew who needs it (1 person) holds a current one.", ask("Is OSHA 30 required on 3001?").answer
  end

  test "a type the project doesn't require, and a closed project" do
    result = ask("Is climber required on 2390?")

    assert_equal :requirements, result.intent
    assert_equal "2390 · Rooftop 2390 doesn't require Authorized Climber. 2390 · Rooftop 2390 is closed.", result.answer
    assert_empty result.sections
  end

  test "a role requirement nobody on the crew holds the role for" do
    ProjectRequirement.where(project: projects(:tower_2417), certificate_type: certificate_types(:cdl_a)).update_all(crew_role_id: crew_roles(:laborer).id)

    assert_equal "2417 · Tower 2417 Upgrade requires CDL Class A for the Laborer role. Nobody on the crew needs it.",
      ask("Does 2417 require a CDL?").answer
  end

  test "an unrelated leftover in an expiry or compliance question is noted, not chased" do
    Project.create!(name: "Golden Water Tank Repaint", code: "GW-12", status: :active)

    %w[expiring expired missing].each do |word|
      result = ask("what's #{word} recently blah")
      assert_equal :list, result.status, result.answer
      assert_empty result.candidates
      assert_includes result.notes, "Ignored “blah”."
    end
  end

  test "a project chip shows the project once, with its status only when not active" do
    choice = ask("what's missing on 2471").candidates.sole
    assert_equal "2417 · Tower 2417 Upgrade", choice.label
    assert_equal "", choice.detail
    assert_equal "what's missing on 2417", choice.question
    assert_equal({ project_id: projects(:tower_2417).id }, choice.pins)

    closed = ask("what's missing on 2391").candidates.sole
    assert_equal [ "2390 · Rooftop 2390", "closed" ], [ closed.label, closed.detail ]
  end

  test "Will and May are only people where a name fits" do
    scenario_will_and_may

    assert_nil ask("Will anyone's first aid expire?").crew_member
    assert_nil ask("who will need flagger on 2417").crew_member
    assert_equal "Will Turner", ask("certs for Will").crew_member&.full_name
  end

  # --- candidates and pins ---

  test "ambiguous people come with re-ask questions and pins" do
    scenario_juana
    juana = CrewMember.find_by!(first_name: "Juana")

    result = ask("Does Juan Orteg have OSHA 30?")

    choice = result.candidates.find { |candidate| candidate.record == juana }
    assert_equal "Does Juana Ortega have OSHA 30?", choice.question
    assert_equal({ crew_member_id: juana.id }, choice.pins)
    assert_equal "ABA Ventures", choice.detail

    pinned = AskQuery.new(choice.question, user: @viewer, crew_member_id: juana.id).call
    assert_equal :check, pinned.intent
    assert_equal :no, pinned.status
    assert_equal juana, pinned.crew_member
  end

  test "two people with the same name are told apart by detail and resolved by pin" do
    twin = CrewMember.create!(first_name: "Juan", last_name: "Ortiz", employer: "Skyline Tower Services")

    result = ask("Does Juan Ortiz have flagger?")

    assert_equal :ambiguous, result.status
    assert_equal "Did you mean Juan Ortiz (Climber · ABA Ventures) or Juan Ortiz (Skyline Tower Services)?", result.answer
    choice = result.candidates.find { |candidate| candidate.record == twin }
    assert_equal({ crew_member_id: twin.id }, choice.pins)

    pinned = AskQuery.new(choice.question, user: @viewer, **choice.pins).call
    assert_equal twin, pinned.crew_member
    assert_equal "No. Juan Ortiz has no Flagger certificate on file.", pinned.answer
  end

  test "ambiguous types re-ask with the type's name" do
    scenario_osha10

    result = ask("Does Juan have OSHA?")

    assert_equal [ "Does Juan have OSHA 10 Construction?", "Does Juan have OSHA 30 Construction?" ], result.candidates.map(&:question).sort
    assert result.candidates.all? { |candidate| candidate.pins.key?(:certificate_type_id) }
  end

  test "a pin for a missing record is ignored" do
    result = AskQuery.new("Does Juan have flagger?", user: @viewer, crew_member_id: 0).call

    assert_equal crew_members(:juan_ortiz), result.crew_member
  end

  test "words the answer didn't use are noted" do
    result = ask("does juan carlos have flagger")

    assert_equal crew_members(:juan_ortiz), result.crew_member
    assert_includes result.notes, "Ignored “carlos”."
  end

  test "a retired type is noted" do
    result = ask("who has hazwoper 40")

    assert_equal certificate_types(:retired_hazwoper), result.certificate_type
    assert_includes result.notes, "HAZWOPER 40 is retired from the master list."
  end

  test "today defaults to Denver's date and can be given" do
    later = Date.current + 20

    result = AskQuery.new("Does Juan have flagger?", user: @viewer, today: later).call

    assert_equal :no, result.status
    assert_match(/the last one expired/, result.answer)
  end

  # --- cost ---

  test "answers run a small fixed number of queries" do
    {
      "Does Jaun Ortis have OSHA 30?" => 5,
      "Who has flagger?" => 5,
      "What does Juan Ortiz have?" => 6,
      "What expires in 60 days?" => 4,
      "What's missing on 2417?" => 6,
      "missing" => 6,
      "Does Juan Orteg have flagger?" => 5,
      "Who doesn't have flagger?" => 5,
      "Which certificates have expired?" => 4,
      "What's required on 2417?" => 7,
      "Does Will have flagger?" => 5
    }.each do |question, limit|
      queries = count_queries { ask(question) }
      assert_operator queries, :<=, limit, "#{question.inspect} ran #{queries} queries"
    end
  end

  test "the query count doesn't grow with the roster" do
    small = count_queries { ask("Who has flagger?") }
    20.times do |index|
      member = CrewMember.create!(first_name: "Worker#{index}", last_name: "Example")
      member.certificates.create!(certificate_type: certificate_types(:flagger), completed_on: Date.current - 30)
    end

    assert_equal small, count_queries { ask("Who has flagger?") }
  end

  private
    def ask(question)
      AskQuery.new(question, user: @viewer, today: Date.current).call
    end

    def date(value)
      value.strftime("%b %-d, %Y")
    end

    def person(value)
      case value
      when Symbol then crew_members(value)
      when String then CrewMember.all.find { |member| member.full_name == value } || flunk("no crew member #{value}")
      end
    end

    def certificate_type(value)
      case value
      when Symbol then certificate_types(value)
      when String then CertificateType.find_by!(code: value)
      end
    end

    def assert_record(expected, actual, message)
      expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
    end

    def assert_answer(expected, actual, message)
      expected = instance_exec(&expected) if expected.is_a?(Proc)
      expected.is_a?(Regexp) ? assert_match(expected, actual, message) : assert_equal(expected, actual, message)
    end

    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ActiveRecord::Base.uncached(&block) }
      count
    end

    # --- scenarios: records a row needs on top of the fixtures (synthetic people only) ---

    def scenario_osha10
      CertificateType.create!(name: "OSHA 10 Construction", code: "OSHA10", aliases: [ "OSHA 10 Hour" ], position: 0)
    end

    def scenario_nicknames
      CrewMember.create!(first_name: "Robert", last_name: "Smith", employer: "Example Safety Training LLC")
      CrewMember.create!(first_name: "William", last_name: "Turner")
      michael = CrewMember.create!(first_name: "Michael", last_name: "Johnson")
      michael.certificates.create!(certificate_type: certificate_types(:first_aid), completed_on: Date.current - 30)
      CrewMember.create!(first_name: "Jesus", last_name: "Ramos")
    end

    def scenario_juana
      CrewMember.create!(first_name: "Juana", last_name: "Ortega", employer: "ABA Ventures")
    end

    def scenario_pedro
      CrewMember.create!(first_name: "Pedro", last_name: "Ortiz", crew_role: crew_roles(:laborer))
    end

    # Automatic flags only (no method recorded, a QR code's details, a lookalike link): each still counts.
    def scenario_flagged
      certificates(:juan_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:not_found], authenticity_method: nil)
      certificates(:li_first_aid).update_columns(authenticity_status: Certificate.authenticity_statuses[:mismatch],
        authenticity_method: "automatic:qr_details_360training")
      certificates(:dave_cdl_a).update_columns(authenticity_status: Certificate.authenticity_statuses[:suspicious],
        authenticity_method: Verification::Run::LINK_METHOD)
    end

    # A person checked both with the issuer (the panel's "Not found" and "Doesn't match"): confirmed fake.
    # Juan's older Flagger is deleted first: a genuine one on file would be current instead (Certificate).
    def scenario_fake
      certificates(:juan_flagger_old).destroy!
      certificates(:juan_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:not_found],
        authenticity_method: Authenticity::PERSON_METHOD)
      certificates(:li_first_aid).update_columns(authenticity_status: Certificate.authenticity_statuses[:mismatch],
        authenticity_method: Authenticity::PERSON_METHOD)
    end

    def scenario_will_and_may
      CrewMember.create!(first_name: "Will", last_name: "Turner")
      may = CrewMember.create!(first_name: "May", last_name: "Lopez")
      may.certificates.create!(certificate_type: certificate_types(:first_aid), completed_on: Date.current - 30)
    end
end
