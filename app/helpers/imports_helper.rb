module ImportsHelper
  BADGE_BASE = "inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium".freeze

  # Full class strings so Tailwind's scanner picks them up.
  BATCH_STATUSES = {
    "receiving" => [ "Receiving", "bg-sky-100 text-sky-800" ],
    "processing" => [ "Processing", "bg-blue-100 text-blue-800" ],
    "needs_review" => [ "Needs review", "bg-amber-100 text-amber-800" ],
    "completed" => [ "Completed", "bg-green-100 text-green-800" ],
    "failed" => [ "Failed", "bg-red-100 text-red-800" ]
  }.freeze

  ITEM_STATUSES = {
    "pending" => [ "Queued", "bg-gray-100 text-gray-700" ],
    "extracting" => [ "Reading", "bg-blue-100 text-blue-800" ],
    "needs_review" => [ "Needs review", "bg-amber-100 text-amber-800" ],
    "accepted" => [ "Accepted", "bg-green-100 text-green-800" ],
    "rejected" => [ "Rejected", "bg-gray-200 text-gray-700" ],
    "duplicate" => [ "Duplicate", "bg-purple-100 text-purple-800" ],
    "failed" => [ "Failed", "bg-red-100 text-red-800" ]
  }.freeze
  WAITING = [ "Waiting for AI budget", "bg-sky-100 text-sky-800" ].freeze

  MATCH_STATES = {
    "matched" => [ "Matched", "bg-green-100 text-green-800" ],
    "suggested" => [ "Suggested", "bg-amber-100 text-amber-800" ],
    "unmatched" => [ "No match", "bg-gray-100 text-gray-600" ],
    "picked" => [ "Picked by hand", "bg-blue-100 text-blue-800" ]
  }.freeze

  PROVIDERS = {
    "workers_ai" => "Cloudflare Workers AI",
    "ollama" => "Ollama (local)",
    "anthropic" => "Anthropic Claude (paid)",
    "fake" => "Fake provider (no AI; test and demo)"
  }.freeze

  # Common reasons offered in the reject box (free text is fine too).
  REJECT_REASONS = [ "Not a certificate", "Unreadable", "Not one of our crew", "Already on file", "Expired long ago" ].freeze

  # frame-refresh intervals (ms) while a batch is being read, and once all that is left is
  # parked until the AI allocation resets at 00:05 UTC.
  REFRESH_INTERVAL = 3_000
  WAITING_REFRESH_INTERVAL = 60_000

  def import_batch_status_badge(batch)
    label, classes = BATCH_STATUSES.fetch(batch.status) { [ batch.status.humanize, "bg-gray-100 text-gray-700" ] }
    tag.span(label, class: "#{BADGE_BASE} #{classes}", data: { status: batch.status })
  end

  # The batch page's "12 files found" (files_count: what unpacking found, zip contents
  # included), or "3 uploads dropped" while they wait to be unpacked; nil when there is
  # neither. The uploads themselves are deleted once unpacked (ImportBatch#discard_uploads!).
  def import_batch_size_label(batch)
    if batch.files_count.positive?
      "#{pluralize(batch.files_count, "file")} found"
    elsif (uploads = batch.uploads.count).positive?
      "#{pluralize(uploads, "upload")} dropped"
    end
  end

  # True while an item is parked until the AI allocation resets.
  def import_item_waiting?(item, now: Time.current)
    item.waiting_for_budget?(now)
  end

  def import_item_status_label(item, now: Time.current)
    return WAITING.first if import_item_waiting?(item, now: now)

    ITEM_STATUSES.fetch(item.status) { [ item.status.humanize ] }.first
  end

  def import_item_status_badge(item, now: Time.current)
    label, classes = import_item_waiting?(item, now: now) ? WAITING : ITEM_STATUSES.fetch(item.status) { [ item.status.humanize, "" ] }
    tag.span(label, class: "#{BADGE_BASE} #{classes}", data: { status: item.status })
  end

  # The badge state for an item's person: its person_match, which is "picked" when a reviewer
  # saved someone the matcher didn't propose ("Save edits").
  def import_person_match_state(item)
    item.person_match.to_s
  end

  # A badge for person_match / type_match ("matched", "suggested", "unmatched", "picked").
  def import_match_badge(state)
    label, classes = MATCH_STATES.fetch(state.to_s, MATCH_STATES["unmatched"])
    tag.span(label, class: "#{BADGE_BASE} #{classes}", data: { match: state })
  end

  # Who "Create crew member from this" may repeat (ImportReviewsController#possible_duplicates):
  # "Juan Ortiz is already on the crew list." and, for inactive members, "Sam Price is on the
  # crew list but inactive (reactivate them from their crew page)." link: true links each name
  # to their crew page (the form's warning); otherwise plain text (an error message).
  def import_duplicate_members_sentence(members, link: false)
    active, inactive = members.partition(&:active?)
    sentences = []
    sentences << [ active, "#{active.one? ? "is" : "are"} already on the crew list." ] if active.any?
    if inactive.any?
      sentences << [ inactive, "#{inactive.one? ? "is" : "are"} on the crew list but inactive " \
                               "(reactivate them from their crew #{"page".pluralize(inactive.size)})." ]
    end

    texts = sentences.map do |group, rest|
      next "#{group.map(&:display_name).to_sentence} #{rest}" unless link

      names = group.map { |member| link_to(member.display_name, crew_member_path(member), class: "font-medium underline", target: "_blank") }
      safe_join([ to_sentence(names), " ", rest ])
    end
    link ? safe_join(texts, " ") : texts.join(" ")
  end

  # "92%", coloured by the auto-accept bar (0.85) and the person-suggestion bar (0.6).
  def import_confidence(confidence)
    return tag.span("—", class: "text-gray-400") if confidence.nil?

    value = confidence.to_f
    classes = if value >= 0.85 then "text-green-700"
    elsif value >= 0.6 then "text-amber-700"
    else "text-red-700"
    end
    tag.span(import_percent(value), class: "tabular-nums font-medium #{classes}", title: "Model confidence")
  end

  # 0.723 -> "72%".
  def import_percent(fraction)
    number_to_percentage(fraction.to_f * 100, precision: 0)
  end

  # "p. 1-2", "p. 3", or nil for a whole file.
  def import_page_label(item)
    pages = item.pages
    return if pages.empty?

    pages.size == 1 ? "p. #{pages.first}" : "p. #{pages.first}-#{pages.last}"
  end

  def import_provider_label(provider)
    PROVIDERS.fetch(provider.to_s) { provider.to_s.humanize.presence || "None" }
  end

  # The model's notes for this item's certificate, wherever the extraction keeps them: a
  # single certificate hash, or the whole-file contract with this item's pages.
  def import_item_notes(item)
    extraction = item.extraction
    return unless extraction.is_a?(Hash)

    certificate = if extraction["certificates"].is_a?(Array)
      certificates = extraction["certificates"].grep(Hash)
      certificates.find { |entry| Array(entry["pages"]) == item.pages } || (certificates.first if certificates.one?)
    else
      extraction
    end
    certificate&.dig("notes").presence
  end

  # Page numbers of the original file the AI skipped: OCR could not read them and no vision
  # model is set (Imports::Extractor's "unread_pages"). The whole-file extraction has them;
  # a further item split from the file finds them on its source item.
  def import_unread_pages(item)
    extraction = [ item.extraction, item.source_item&.extraction ].find { |data| data.is_a?(Hash) && data.key?("unread_pages") }
    pages = extraction&.fetch("unread_pages")
    pages.is_a?(Array) ? pages.filter_map { |page| Integer(page.to_s, exception: false) }.uniq.sort : []
  end

  # Options for a picker with the matcher's suggestions first ("Juan Ortiz · 72% match", plus
  # any note such as "inactive crew member"), then every record. Only the first option for
  # selected_id is marked selected. A record's attributes (e.g. data for a Stimulus
  # controller) also go on its suggestion. The select's own include_blank is the placeholder.
  #   suggestions: [{ "id" =>, "name" =>, "similarity" =>, "note" => }]
  #   records: [[label, id], ...] or [[label, id, { data: { ... } }], ...]
  def import_picker_options(suggestions:, records:, selected_id:)
    selected_id = selected_id.presence&.to_i
    attributes = records.to_h { |_label, id, extra| [ id, extra || {} ] }
    selected_done = false
    option = lambda do |label, id|
      selected = !selected_done && id == selected_id
      selected_done ||= selected
      tag.option(label, value: id, selected: selected, **attributes.fetch(id, {}))
    end

    suggested = Array(suggestions).filter_map do |suggestion|
      id = suggestion["id"].to_i
      next if id.zero?

      similarity = suggestion["similarity"]
      details = [ ("#{import_percent(similarity)} match" unless similarity.nil?), suggestion["note"].presence ].compact
      option.call([ suggestion["name"].to_s, *details ].join(" · "), id)
    end
    everything = records.map { |label, id| option.call(label, id) }

    groups = []
    groups << tag.optgroup(safe_join(suggested), label: "Suggested") if suggested.any?
    groups << tag.optgroup(safe_join(everything), label: "All") if everything.any?
    safe_join(groups)
  end

  # The review form's type options, then "Other…", whose hint is a new type's default validity.
  def import_type_options(suggestions:, records:, selected_id:)
    other = selected_id.to_s == CertificateIssuersHelper::OTHER_VALUE
    safe_join([ import_picker_options(suggestions:, records:, selected_id: (selected_id unless other)),
      tag.option(CertificateIssuersHelper::OTHER_LABEL, value: CertificateIssuersHelper::OTHER_VALUE, selected: other,
        data: { name: "A new type", validity_months: CertificateType::DEFAULT_VALIDITY_MONTHS }) ])
  end

  # A type picker option's data for the review-expiry controller, which keeps the expiry
  # hint in step with the type picked.
  def import_type_option_attributes(type)
    rule = type.never_expires? ? { never_expires: true } : { validity_months: type.validity_months }
    { data: { name: type.name, **rule } }
  end

  # The end of the review form's expiry hint ("Leave it blank to work it out from the
  # type..."): what a blank expiry works out to for this type and completion date.
  # review_expiry_controller.js builds the same text in the browser.
  def import_expiry_rule(type, completed_on)
    return "." if type.nil?
    return ": #{type.name} never expires." if type.never_expires?

    months = pluralize(type.validity_months, "month")
    return ": completed date plus #{months}." if completed_on.nil?

    ": #{format_date(type.expiry_for(completed_on))} (completed plus #{months})."
  end

  # ImportBatch#progress with string keys: every item status plus "waiting_for_budget",
  # each defaulting to 0.
  def import_progress_counts(progress)
    progress = progress.to_h.stringify_keys
    [ *ImportItem.statuses.keys, "waiting_for_budget" ].index_with { |key| progress.fetch(key, 0).to_i }
  end

  # True when a batch's progress has items left to read and every one of them is parked
  # until the AI allocation resets.
  def import_only_waiting?(progress)
    counts = import_progress_counts(progress)
    in_flight = counts["pending"] + counts["extracting"]
    in_flight.positive? && counts["waiting_for_budget"] >= in_flight
  end

  # frame-refresh interval (ms) for live batches' progress: slow only when every one of them
  # is just waiting for the 00:05 UTC reset (a batch still being unpacked has no items yet).
  def import_refresh_interval(progresses)
    progresses.all? { |progress| import_only_waiting?(progress) } ? WAITING_REFRESH_INTERVAL : REFRESH_INTERVAL
  end

  # "Nov 4, 2026 5:05 PM MST"; times are shown in the app's zone (America/Denver).
  def import_time(time)
    return "—" if time.nil?

    time = time.in_time_zone
    tag.time(time.strftime("%b %-d, %Y %-l:%M %p %Z"), datetime: time.iso8601)
  end
end
