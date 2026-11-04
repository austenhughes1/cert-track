require "test_helper"

class ImportsHelperTest < ActionView::TestCase
  include ComplianceHelper # format_date, which views get from every helper

  test "import_page_label" do
    assert_equal "p. 1-2", import_page_label(ImportItem.new(page_range: "1-2"))
    assert_equal "p. 3", import_page_label(ImportItem.new(page_range: "3"))
    assert_nil import_page_label(ImportItem.new(page_range: nil))
  end

  test "import_confidence colours by the auto-accept and suggestion bars" do
    assert_dom_equal %(<span class="tabular-nums font-medium text-green-700" title="Model confidence">92%</span>), import_confidence(0.92)
    assert_includes import_confidence(BigDecimal("0.85")), "text-green-700"
    assert_includes import_confidence(0.62), "text-amber-700"
    assert_includes import_confidence(0.3), "text-red-700"
    assert_includes import_confidence(nil), "—"
  end

  test "status badges" do
    assert_includes import_batch_status_badge(ImportBatch.new(status: :needs_review)), "Needs review"
    assert_includes import_item_status_badge(ImportItem.new(status: :duplicate)), "Duplicate"
    assert_includes import_item_status_badge(ImportItem.new(status: :pending)), "Queued"

    now = Time.current
    waiting = ImportItem.new(status: :extracting, next_attempt_at: now + 1.hour)
    assert_equal "Waiting for AI budget", import_item_status_label(waiting, now: now)
    assert_equal "Reading", import_item_status_label(waiting, now: now + 2.hours)
    assert_equal "Accepted", import_item_status_label(ImportItem.new(status: :accepted, next_attempt_at: now + 1.hour), now: now)
  end

  test "import_match_badge" do
    assert_includes import_match_badge("matched"), "Matched"
    assert_includes import_match_badge("suggested"), "Suggested"
    assert_includes import_match_badge("unmatched"), "No match"
    assert_includes import_match_badge("picked"), "Picked by hand"
  end

  test "import_person_match_state: a saved pick the matcher didn't propose is picked by hand" do
    li = crew_members(:li_chen)

    assert_equal "picked", import_person_match_state(ImportItem.new(matched_crew_member: li, person_match: :picked))
    assert_equal "unmatched", import_person_match_state(ImportItem.new(person_match: :unmatched))
    assert_equal "suggested", import_person_match_state(ImportItem.new(matched_crew_member: li, person_match: :suggested))
    assert_equal "matched", import_person_match_state(ImportItem.new(matched_crew_member: li, person_match: :matched))
  end

  test "import_provider_label" do
    assert_equal "Cloudflare Workers AI", import_provider_label("workers_ai")
    assert_equal "Anthropic Claude (paid)", import_provider_label(:anthropic)
    assert_equal "Something new", import_provider_label("something_new")
  end

  test "import_picker_options puts suggestions first and selects only one option" do
    html = import_picker_options(
      suggestions: [ { "id" => 7, "name" => "Juan Ortiz", "similarity" => 0.723 }, { "id" => 9, "name" => "Sam Price", "similarity" => 0.61, "note" => "inactive crew member" } ],
      records: [ [ "Chen, Li", 3 ], [ "Ortiz, Juan", 7 ] ], selected_id: "7"
    )
    fragment = Nokogiri::HTML5.fragment(html)

    assert_equal [ "Juan Ortiz · 72% match", "Sam Price · 61% match · inactive crew member", "Chen, Li", "Ortiz, Juan" ],
      fragment.css("option").map(&:text)
    assert_equal %w[Suggested All], fragment.css("optgroup").map { |group| group["label"] }
    assert_equal [ "Juan Ortiz · 72% match" ], fragment.css("option[selected]").map(&:text)
  end

  test "import_picker_options without suggestions or a selection" do
    fragment = Nokogiri::HTML5.fragment(import_picker_options(suggestions: [], records: [ [ "Flagger", 2 ] ], selected_id: nil))

    assert_equal %w[All], fragment.css("optgroup").map { |group| group["label"] }
    assert_empty fragment.css("option[selected]")
    assert_empty fragment.css("option[value='']"), "the select's own include_blank is the placeholder"
  end

  test "import_picker_options gives a record's attributes to its suggestion too" do
    html = import_picker_options(suggestions: [ { "id" => 2, "name" => "Flagger", "similarity" => 0.9 }, { "id" => 5, "name" => "Gone" } ],
      records: [ [ "Flagger (FLAGGER)", 2, { data: { validity_months: 36 } } ], [ "OSHA 30", 1, { data: { never_expires: true } } ] ], selected_id: 2)
    fragment = Nokogiri::HTML5.fragment(html)

    assert_equal [ "36", "36" ], fragment.css("option[value='2']").map { |option| option["data-validity-months"] }
    assert_equal [ "Flagger · 90% match" ], fragment.css("option[selected]").map(&:text)
    assert fragment.at_css("option[value='1'][data-never-expires]")
    assert_nil fragment.at_css("option[value='5']").attributes["data-validity-months"]
  end

  test "import_picker_options escapes names" do
    html = import_picker_options(suggestions: [ { "id" => 1, "name" => "<b>Bob</b>" } ], records: [], selected_id: nil)

    assert_includes html, "&lt;b&gt;Bob&lt;/b&gt;"
  end

  test "import_duplicate_members_sentence says who is on the crew list, and who is inactive there" do
    juan, li, sam = crew_members(:juan_ortiz), crew_members(:li_chen), crew_members(:sam_inactive)

    assert_equal "Juan Ortiz and Li Chen are already on the crew list.", import_duplicate_members_sentence([ juan, li ])
    assert_equal "Sam Price is on the crew list but inactive (reactivate them from their crew page).",
      import_duplicate_members_sentence([ sam ])
    other_sam = CrewMember.new(id: 0, first_name: "Sam", last_name: "Price", active: false)
    assert_equal "Juan Ortiz is already on the crew list. Sam Price and Sam Price are on the crew list but inactive " \
      "(reactivate them from their crew pages).", import_duplicate_members_sentence([ sam, juan, other_sam ])
  end

  test "import_duplicate_members_sentence links each name to their crew page, escaped" do
    sam = crew_members(:sam_inactive)
    sam.first_name = "<b>Sam</b>"
    html = import_duplicate_members_sentence([ sam ], link: true)

    assert_predicate html, :html_safe?
    assert_dom_equal %(<a class="font-medium underline" target="_blank" href="#{crew_member_path(sam)}">&lt;b&gt;Sam&lt;/b&gt; Price</a> ) +
      "is on the crew list but inactive (reactivate them from their crew page).", html
  end

  test "import_item_notes reads the notes for the item's own certificate" do
    whole_file = { "certificates" => [ { "pages" => [ 1 ], "notes" => "first" }, { "pages" => [ 2, 3 ], "notes" => "second" } ] }
    assert_equal "second", import_item_notes(ImportItem.new(page_range: "2-3", extraction: whole_file))
    assert_nil import_item_notes(ImportItem.new(page_range: "5", extraction: whole_file))
    assert_equal "only", import_item_notes(ImportItem.new(page_range: nil, extraction: { "certificates" => [ { "pages" => [ 1 ], "notes" => "only" } ] }))
    assert_equal "flat", import_item_notes(ImportItem.new(extraction: { "pages" => [ 1 ], "notes" => "flat" }))
    assert_nil import_item_notes(ImportItem.new(extraction: nil))
    assert_nil import_item_notes(ImportItem.new(extraction: { "certificates" => [ { "pages" => [ 1 ], "notes" => "" } ] }))
  end

  test "import_type_option_attributes describes a type for the expiry hint" do
    assert_equal({ data: { name: "Flagger", validity_months: 36 } }, import_type_option_attributes(certificate_types(:flagger)))
    assert_equal({ data: { name: "OSHA 30 Construction", never_expires: true } }, import_type_option_attributes(certificate_types(:osha30)))
  end

  test "import_expiry_rule says what a blank expiry works out to" do
    flagger = certificate_types(:flagger)

    assert_equal ": Mar 14, 2028 (completed plus 36 months).", import_expiry_rule(flagger, Date.new(2025, 3, 14))
    assert_equal ": completed date plus 36 months.", import_expiry_rule(flagger, nil)
    assert_equal ": OSHA 30 Construction never expires.", import_expiry_rule(certificate_types(:osha30), Date.new(2025, 3, 14))
    assert_equal ".", import_expiry_rule(nil, Date.new(2025, 3, 14))
    flagger.validity_months = 1
    assert_equal ": Feb 28, 2025 (completed plus 1 month).", import_expiry_rule(flagger, Date.new(2025, 1, 31))
  end

  test "import_unread_pages reads the whole-file extraction, or the source item's" do
    source = ImportItem.new(extraction: { "certificates" => [], "unread_pages" => [ 4, 2, "3", nil ] })

    assert_equal [ 2, 3, 4 ], import_unread_pages(source)
    assert_equal [ 2, 3, 4 ], import_unread_pages(ImportItem.new(source_item: source, extraction: { "certificates" => [ { "pages" => [ 1 ] } ] }))
    assert_equal [], import_unread_pages(ImportItem.new(extraction: { "certificates" => [] }))
    assert_equal [], import_unread_pages(ImportItem.new(extraction: nil))
    assert_equal [], import_unread_pages(ImportItem.new(extraction: { "unread_pages" => "2" }))
  end

  test "import_refresh_interval slows down only when everything left waits for the AI reset" do
    assert_equal 60_000, import_refresh_interval([ { extracting: 2, waiting_for_budget: 2 }, { pending: 1, waiting_for_budget: 1 } ])
    assert_equal 3_000, import_refresh_interval([ { extracting: 2, waiting_for_budget: 2 }, { pending: 1 } ])
    assert_equal 3_000, import_refresh_interval([ { extracting: 2, waiting_for_budget: 1 } ])
    assert_equal 3_000, import_refresh_interval([ {} ]), "a batch with nothing in it yet is being unpacked"
  end

  test "import_progress_counts fills every key" do
    counts = import_progress_counts({ pending: 2, needs_review: 1, waiting_for_budget: 1, total: 3 })

    assert_equal 2, counts["pending"]
    assert_equal 0, counts["failed"]
    assert_equal 1, counts["waiting_for_budget"]
    assert_equal (ImportItem.statuses.keys + %w[waiting_for_budget]).sort, counts.keys.sort
  end

  test "import_time shows the app's zone" do
    html = import_time(Time.utc(2026, 11, 5, 0, 5))

    assert_includes html, "Nov 4, 2026 5:05 PM MST"
    assert_includes html, %(datetime="2026-11-04T17:05:00-07:00")
    assert_equal "—", import_time(nil)
  end
end
