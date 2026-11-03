module AskHelper
  STATUS_LABELS = {
    yes: "Yes", no: "No", list: "Answer", ambiguous: "Which one?", not_found: "Not found", unknown: "Not sure"
  }.freeze

  # Full class strings so Tailwind's scanner picks them up.
  CARD_CLASSES = {
    yes: "border-green-200 bg-green-50",
    no: "border-red-200 bg-red-50",
    list: "border-gray-200 bg-white",
    ambiguous: "border-amber-200 bg-amber-50",
    not_found: "border-amber-200 bg-amber-50",
    unknown: "border-gray-200 bg-white"
  }.freeze

  BADGE_CLASSES = {
    yes: "bg-green-600 text-white",
    no: "bg-red-600 text-white",
    list: "bg-blue-100 text-blue-800",
    ambiguous: "bg-amber-100 text-amber-800 ring-1 ring-inset ring-amber-600/30",
    not_found: "bg-amber-100 text-amber-800 ring-1 ring-inset ring-amber-600/30",
    unknown: "bg-gray-100 text-gray-700"
  }.freeze

  BADGE_BASE = "inline-flex shrink-0 items-center rounded-full px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wide".freeze

  def ask_status_label(status)
    STATUS_LABELS.fetch(status.to_sym)
  end

  # The pill at the top of an answer card: "Yes", "No", "Answer", "Which one?" ...
  def ask_status_badge(status)
    tag.span(ask_status_label(status), class: "#{BADGE_BASE} #{BADGE_CLASSES.fetch(status.to_sym)}", data: { status: status })
  end

  # Border and background for the answer card.
  def ask_card_classes(status)
    CARD_CLASSES.fetch(status.to_sym)
  end

  # Re-asks the candidate's question, pinned to its record.
  def ask_candidate_path(candidate)
    ask_path(q: candidate.question, **candidate.pins)
  end

  # "in 10 days", "today", "5 days ago"; nil when there is no expiry date.
  def ask_relative_expiry(expires_on, today: Date.current)
    Ask::Wording.in_days((expires_on - today).to_i) if expires_on
  end

  # "[View]" links for a yes/no answer: the certificate when there is one, and the person.
  def ask_check_links(result)
    item = result.evidence.first
    return unless item

    links = []
    if item.certificate
      links << link_to("View certificate", crew_member_certificate_path(item.crew_member, item.certificate),
        class: "font-medium text-blue-700 hover:underline")
    end
    links << link_to("View #{item.crew_member.display_name}", crew_member_path(item.crew_member),
      class: "font-medium text-blue-700 hover:underline")
    safe_join(links, tag.span(" · ", class: "text-gray-400"))
  end

  # Which columns an evidence table needs: no person column when the answer is about one
  # person, no type column when it is about one type.
  def ask_columns(result)
    filtered = %i[expiring expired gaps].include?(result.intent)
    { person: !(result.intent == :list_certificates || (filtered && result.crew_member)),
      certificate_type: !(%i[list_holders lacking].include?(result.intent) || (filtered && result.certificate_type)) }
  end
end
