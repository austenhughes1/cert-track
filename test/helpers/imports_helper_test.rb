require "test_helper"

class ImportsHelperTest < ActionView::TestCase
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

    assert_equal "picked", import_person_match_state(ImportItem.new(matched_crew_member: li, person_match: :unmatched))
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
      records: [ [ "Chen, Li", 3 ], [ "Ortiz, Juan", 7 ] ], selected_id: "7", blank: "Choose a person"
    )
    fragment = Nokogiri::HTML5.fragment(html)

    assert_equal [ "Choose a person", "Juan Ortiz · 72% match", "Sam Price · 61% match · inactive crew member", "Chen, Li", "Ortiz, Juan" ],
      fragment.css("option").map(&:text)
    assert_equal %w[Suggested All], fragment.css("optgroup").map { |group| group["label"] }
    assert_equal [ "Juan Ortiz · 72% match" ], fragment.css("option[selected]").map(&:text)
  end

  test "import_picker_options without suggestions or a selection" do
    fragment = Nokogiri::HTML5.fragment(import_picker_options(suggestions: [], records: [ [ "Flagger", 2 ] ], selected_id: nil, blank: "Choose a type"))

    assert_equal %w[All], fragment.css("optgroup").map { |group| group["label"] }
    assert_empty fragment.css("option[selected]")
    assert_equal "", fragment.css("option").first["value"]
  end

  test "import_picker_options escapes names" do
    html = import_picker_options(suggestions: [ { "id" => 1, "name" => "<b>Bob</b>" } ], records: [], selected_id: nil, blank: "Pick")

    assert_includes html, "&lt;b&gt;Bob&lt;/b&gt;"
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
