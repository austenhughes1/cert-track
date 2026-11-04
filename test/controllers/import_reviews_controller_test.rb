require "test_helper"

class ImportReviewsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @item = import_items(:review_juan_first_aid) # needs review: "Jaun Ortis", no person, type first_aid
    @item.file.attach(blob("certificate.pdf"))
    @juan = crew_members(:juan_ortiz)
    @first_aid = certificate_types(:first_aid)
  end

  # --- access ---

  test "requires sign-in" do
    get import_reviews_path
    assert_redirected_to new_session_path
  end

  test "viewers get 403 on every review action, reads included" do
    sign_in_as users(:viewer)

    get import_reviews_path
    assert_response :forbidden
    get import_review_path(@item)
    assert_response :forbidden
    patch import_review_path(@item), params: { review: review_params }
    assert_response :forbidden
    %i[accept reject skip create_crew_member merge reread].each do |action|
      post send("#{action}_import_review_path", @item), params: { review: review_params, crew_member: { first_name: "A", last_name: "B" } }
      assert_response :forbidden, "#{action} should be forbidden to a viewer"
    end
    assert @item.reload.needs_review?
    assert_nil @item.skipped_at
  end

  test "managers and admins can review" do
    %i[manager admin].each do |role|
      sign_in_as users(role)
      get import_reviews_path
      assert_response :success, "#{role} should see the queue"
      get import_review_path(@item)
      assert_response :success, "#{role} should see an item"
      sign_out
    end
  end

  test "the dashboard review tile links editors to the queue, not viewers" do
    sign_in_as users(:manager)
    get root_path
    assert_select "a#tile_review_queue[href=?]", import_reviews_path

    sign_in_as users(:viewer)
    get root_path
    assert_select "#tile_review_queue"
    assert_select "a#tile_review_queue", count: 0
  end

  # --- index ---

  test "index lists items waiting for review in queue order with counts" do
    second = new_item(original_filename: "crew.zip/li.jpg", holder_name_raw: "Li Chen", matched_crew_member: crew_members(:li_chen),
      person_match: :matched, matched_certificate_type: certificate_types(:flagger), type_match: :suggested, confidence: 0.91)
    skipped = new_item(original_filename: "maria.pdf", page_range: "3", skipped_at: 1.hour.ago)
    new_item(status: :pending)
    sign_in_as users(:manager)

    get import_reviews_path

    assert_response :success
    assert_select "title", "Review queue · CertTrack"
    assert_select "#review_counts", /3 items waiting for review, 1 of them skipped once/
    assert_select "#review_counts", /1 more item still being read/
    rows = css_select("#review_items tbody tr").map { |row| row["id"] }
    assert_equal [ @item, second, skipped ].map { |item| "import_item_#{item.id}" }, rows
    assert_select "#start_reviewing[href=?]", import_review_path(@item)

    assert_select "tr#import_item_#{@item.id}" do
      assert_select "td", /Jaun Ortis/
      assert_select "[data-match=unmatched]", text: "No match", count: 1 # the person
      assert_select "[data-match=suggested]", text: "Suggested", count: 1 # the type, by name
      assert_select "td", "62%"
      assert_select "a[href=?]", import_path(@item.import_batch_id)
    end
    assert_select "tr#import_item_#{second.id}" do
      assert_select "td", /Li Chen/
      assert_select "[data-match=matched]", "Matched"
      assert_select "[data-match=suggested]", "Suggested"
    end
    assert_select "tr#import_item_#{skipped.id}", /p\. 3\s+· skipped/
  end

  test "index empty state" do
    ImportItem.needs_review.update_all(status: ImportItem.statuses[:rejected])
    sign_in_as users(:manager)

    get import_reviews_path

    assert_select "#review_items", count: 0
    assert_select "body", /Nothing to review/
    assert_select "#start_reviewing", count: 0
  end

  # --- show ---

  test "show puts the PDF on the left and the editable proposal on the right" do
    freeze_time # blob links expire (urls_expire_in): the page's link and the expected one are minted at the same time
    @item.update!(person_suggestions: [ { "id" => @juan.id, "name" => "Juan Ortiz", "similarity" => 0.47 } ], person_match: :suggested,
      matched_crew_member: @juan, type_suggestions: [ { "id" => @first_aid.id, "name" => @first_aid.name, "similarity" => 0.81 } ],
      type_match: :suggested, issuer_raw: "Example Safety Training LLC", proposed_certificate_number: "FA-2201",
      extraction: { "certificates" => [ { "pages" => [ 2 ], "notes" => "Wallet card, back side blank" } ] })
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_response :success
    assert_select "title", "Review · scan_0001.pdf p. 2 · CertTrack"
    assert_select "#review_position", "Item 1 of 1 waiting"
    assert_select "#review_preview_pdf[src=?]", rails_blob_path(@item.file, disposition: "inline")
    assert_select "#review_page_range", "Page 2 of the original file"
    assert_select "#raw_holder_name", "Jaun Ortis"
    assert_select "#raw_certificate_name", "Adult First Aid CPR AED"
    assert_select "#raw_confidence", "62%"
    assert_select "#raw_notes", "Wallet card, back side blank"

    assert_select "form#review_form[action=?][method=post]", accept_import_review_path(@item) do
      assert_select "select[name=?]", "review[crew_member_id]" do
        assert_select "optgroup[label=Suggested] option[value=?][selected]", @juan.id.to_s, text: "Juan Ortiz · 47% match"
        assert_select "optgroup[label=All] option[value=?]", crew_members(:li_chen).id.to_s, text: "Chen, Li"
        assert_select "optgroup[label=All] option[value=?]:not([selected])", @juan.id.to_s
        assert_select "option[value=?]", crew_members(:sam_inactive).id.to_s, count: 0 # inactive crew aren't offered
      end
      assert_select "select[name=?] optgroup[label=Suggested] option[value=?][selected]", "review[certificate_type_id]",
        @first_aid.id.to_s, text: "First Aid/CPR/AED · 81% match"
      assert_select "input[type=date][name=?][value=?]", "review[completed_on]", @item.proposed_completed_on.iso8601
      assert_select "input[type=date][name=?]:not([value])", "review[expires_on]"
      assert_select "#review_expires_on_hint", /#{Regexp.escape(format_date(@item.proposed_completed_on + 24.months))} \(completed plus 24 months\)/
      assert_select "input[name=?][value=?]", "review[certificate_number]", "FA-2201"
      assert_select "input[name=?][value=?]", "review[issued_by]", "Example Safety Training LLC"
      assert_select "button[data-review-shortcuts-target=accept]", "Accept"
      assert_select "button[name=_method][value=patch][formaction=?]", import_review_path(@item), text: "Save edits"
    end
    assert_select "form#reject_form[action=?] button[data-review-shortcuts-target=reject]", reject_import_review_path(@item)
    assert_select "form#skip_form[action=?] button[data-review-shortcuts-target=skip]", skip_import_review_path(@item)
    assert_select "[data-controller=review-shortcuts][data-action*=?]", "keydown@document->review-shortcuts#press"
    assert_select "#review_shortcut_hints kbd", 3
    assert_select "#merge_candidates", count: 0
  end

  test "show prefills a printed expiry and offers 'create crew member' when nobody matched" do
    @item.update!(holder_name_raw: "ORTEGA, JUANA M.", proposed_expires_on: Date.current + 300, proposed_expires_on_source: :printed)
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "input[type=date][name=?][value=?]", "review[expires_on]", (Date.current + 300).iso8601
    assert_select "select[name=?] optgroup[label=Suggested]", "review[crew_member_id]", count: 0
    assert_select "select[name=?] option[selected]", "review[crew_member_id]", count: 0
    assert_select "details#new_crew_member[open]" do
      assert_select "form[action=?]", create_crew_member_import_review_path(@item)
      assert_select "input[name=?][value=?]", "crew_member[first_name]", "Juana"
      assert_select "input[name=?][value=?]", "crew_member[last_name]", "Ortega"
    end
    assert_select "a[href='#new_crew_member']", /Create a crew member from this/
  end

  test "each picker has one placeholder, and it shows when nothing is proposed" do
    @item.update!(matched_certificate_type: nil, type_match: :unmatched, type_suggestions: [])
    sign_in_as users(:manager)

    get import_review_path(@item)

    { "crew_member_id" => "Choose a person", "certificate_type_id" => "Choose a type" }.each do |field, placeholder|
      options = css_select("select[name='review[#{field}]'] option")
      assert_equal [ placeholder ], options.select { |option| option["value"].to_s.empty? }.map(&:text), "#{field}: one blank option"
      assert_equal placeholder, options.first.text, "#{field}: the placeholder comes first"
      assert_empty options.select { |option| option["selected"] }, "#{field}: nothing selected, so the browser shows the placeholder"
    end
  end

  test "type options carry their validity, so the expiry hint can follow the type picked" do
    @item.update!(type_suggestions: [ { "id" => @first_aid.id, "name" => @first_aid.name, "similarity" => 0.81 } ])
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "form#review_form[data-controller~=review-expiry]" do
      assert_select "select[name=?][data-review-expiry-target=type][data-action~=?]", "review[certificate_type_id]", "change->review-expiry#update"
      assert_select "input[name=?][data-review-expiry-target=completed][data-action~=?]", "review[completed_on]", "input->review-expiry#update"
      assert_select "option[value=?][data-name=?][data-validity-months='24']", @first_aid.id.to_s, @first_aid.name, count: 2 # suggested, and in All
      assert_select "optgroup[label=All] option[value=?][data-name=?][data-never-expires]", certificate_types(:osha30).id.to_s, "OSHA 30 Construction"
      assert_select "optgroup[label=All] option[value=?]:not([data-validity-months])", certificate_types(:osha30).id.to_s
      assert_select "option[value='']:not([data-name])"
    end
    assert_select "#review_expires_on_hint [data-review-expiry-target=rule]",
      ": #{format_date(@item.proposed_completed_on + 24.months)} (completed plus 24 months)."
  end

  test "the expiry hint says when the picked type never expires, or that it needs a completion date" do
    osha30 = certificate_types(:osha30)
    sign_in_as users(:manager)

    patch import_review_path(@item), params: { review: review_params(certificate_type_id: osha30.id) }
    get import_review_path(@item)
    assert_select "#review_expires_on_hint [data-review-expiry-target=rule]", ": OSHA 30 Construction never expires."

    post accept_import_review_path(@item), params: { review: review_params(completed_on: "", crew_member_id: "") }
    assert_select "#review_expires_on_hint [data-review-expiry-target=rule]", ": completed date plus 24 months."

    post accept_import_review_path(@item), params: { review: review_params(certificate_type_id: "", crew_member_id: "") }
    assert_select "#review_expires_on_hint [data-review-expiry-target=rule]", "."
  end

  test "show lists the pages the AI could not read" do
    @item.update!(extraction: { "certificates" => [ { "pages" => [ 2 ], "notes" => "Pages 3 and 4 were not read." } ],
                                "non_certificate_pages" => [], "unread_pages" => [ 3, 4 ] })
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "#review_raw #raw_unread_pages" do
      assert_select "dt", "Pages not read"
      assert_select "dd", "3, 4. Set EXTRACTION_VISION_MODEL to read scanned pages."
    end
  end

  test "an item split from a file reads the file's unread pages from its source item" do
    @item.update!(extraction: { "certificates" => [ { "pages" => [ 2 ] } ], "non_certificate_pages" => [], "unread_pages" => [ 3 ] })
    split = new_item(page_range: "1", source_item: @item, extraction: { "certificates" => [ { "pages" => [ 1 ] } ], "non_certificate_pages" => [] })
    plain = new_item(extraction: { "certificates" => [ { "pages" => [ 1 ] } ], "non_certificate_pages" => [] })
    sign_in_as users(:manager)

    get import_review_path(split)
    assert_select "#raw_unread_pages dd", "3. Set EXTRACTION_VISION_MODEL to read scanned pages."

    get import_review_path(plain)
    assert_select "#raw_unread_pages", count: 0
  end

  test "an expiry printed on the card but unreadable makes the expiry field required and says why" do
    @item.update!(extraction: unreadable_expiry_extraction("06/2027"),
      error_message: "The expiration date \"06/2027\" is not a valid YYYY-MM-DD date.")
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "input[type=date][name=?][required][aria-invalid=true][aria-describedby~=review_expires_on_unreadable]", "review[expires_on]"
    assert_select "label[for=review_expires_on]", /Expires on\s+\(required\)/
    assert_select "#review_expires_on_unreadable[role=alert]",
      "The card's expiry (\"06/2027\") could not be read. Type the expiry date from the card."

    typed = Date.current + 200 # once the reviewer has typed and saved it, it is still required but no longer flagged
    patch import_review_path(@item), params: { review: review_params(expires_on: typed.iso8601) }
    get import_review_path(@item)
    assert_select "input[type=date][name=?][value=?][required]:not([aria-invalid])", "review[expires_on]", typed.iso8601
    assert_select "#review_expires_on_unreadable:not([role])", /could not be read/

    @item.update!(extraction: { "certificates" => [ { "pages" => [ 2 ], "holder_name" => "Jaun Ortis" } ] }, error_message: nil)
    get import_review_path(@item)
    assert_select "input[type=date][name=?]:not([required])", "review[expires_on]"
    assert_select "#review_expires_on_unreadable", count: 0
  end

  test "a card that says it never expires is accepted with the expiry left blank" do
    osha30 = certificate_types(:osha30)
    printed = { "pages" => [ 2 ], "holder_name" => "Jaun Ortis", "certificate_type_code" => "OSHA30", "expires_on" => "Does not expire" }
    @item.update!(matched_certificate_type: osha30, type_match: :matched,
      extraction: Imports::Extraction::Normalizer.new(pages: [ 2 ], codes: [ "OSHA30" ]).call("certificates" => [ printed ]))
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "input[type=date][name=?]:not([required])", "review[expires_on]"
    assert_select "#review_expires_on_unreadable", count: 0
    assert_select "#review_expires_on_hint", /Leave it blank to work it out from the type: OSHA 30 Construction never expires\./
    assert_select "#raw_notes", %(No expiry date printed (the card says "Does not expire").)

    post accept_import_review_path(@item), params: { review: review_params(certificate_type_id: osha30.id, expires_on: "") }

    assert @item.reload.accepted?
    assert @item.certificate.expiry_none?
  end

  test "show renders image items as images, HEIC through a variant" do
    freeze_time # blob links expire (urls_expire_in): the page's link and the expected one are minted at the same time
    jpeg = new_item(original_filename: "crew.zip/ortiz.jpg", page_range: nil)
    jpeg.file.attach(blob("certificate.jpg"))
    heic = new_item(original_filename: "IMG_0042.HEIC", page_range: nil)
    heic.file.attach(blob("certificate.heic"))
    sign_in_as users(:manager)

    get import_review_path(jpeg)
    assert_select "img#review_preview_image[src=?]", rails_blob_path(jpeg.file, disposition: "inline")
    assert_select "#review_preview_pdf", count: 0
    assert_select "#review_page_range", count: 0

    get import_review_path(heic)
    assert_select "img#review_preview_image[src*=?]", "/rails/active_storage/representations/redirect/"
  end

  test "show without a file says so" do
    @item.file.purge
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_response :success
    assert_select "#review_preview_missing", /No file attached/
  end

  test "extracted text is shown collapsed and HTML-escaped" do
    @item.update!(extracted_text: "=== page 2 ===\n<script>alert('x')</script> & <b>bold</b>")
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "details#extracted_text:not([open]) pre", /<script>alert\('x'\)<\/script> & <b>bold<\/b>/
    assert_includes response.body, "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &lt;b&gt;bold&lt;/b&gt;"
    assert_not_includes response.body, "<script>alert('x')</script>"
    assert_select "#extracted_text b", count: 0
  end

  test "an item that is no longer in the queue redirects to its batch" do
    accepted = import_items(:accepted_li_flagger)
    sign_in_as users(:manager)

    get import_review_path(accepted)
    assert_redirected_to import_path(accepted.import_batch)
    assert_match(/no longer waiting for review \(accepted\)/, flash[:notice])

    head import_review_path(accepted) # routed like GET, so it behaves like GET
    assert_redirected_to import_path(accepted.import_batch)

    post accept_import_review_path(accepted), params: { review: review_params }
    assert_redirected_to import_review_path(@item)
    assert_match(/no longer waiting for review/, flash[:alert])
  end

  # --- accept ---

  test "accept with edits creates a verified certificate and moves to the next item" do
    following = new_item(original_filename: "next.pdf")
    completed_on = Date.current - 30
    sign_in_as users(:manager)

    assert_difference -> { Certificate.count }, 1 do
      post accept_import_review_path(@item), params: { review: review_params(completed_on: completed_on.iso8601) }
    end

    assert_redirected_to import_review_path(following)
    certificate = Certificate.order(:id).last
    assert_equal "Accepted First Aid/CPR/AED for Juan Ortiz.", flash[:notice]
    assert_equal @juan, certificate.crew_member
    assert_equal @first_aid, certificate.certificate_type
    assert_equal completed_on, certificate.completed_on
    assert_equal completed_on + 24.months, certificate.expires_on
    assert certificate.expiry_computed?
    assert_equal "FA-77001", certificate.certificate_number
    assert_equal "Example Safety Training LLC", certificate.issued_by
    assert certificate.source_import?
    assert_equal users(:manager), certificate.verified_by
    assert_equal [ @item.file.blob ], certificate.files.map(&:blob)

    @item.reload
    assert @item.accepted?
    assert_equal certificate, @item.certificate
    assert_equal users(:manager), @item.reviewed_by
  end

  test "accept keeps a printed expiry and lets a typed one through" do
    printed = Date.current + 400
    @item.update!(proposed_expires_on: printed, proposed_expires_on_source: :printed)
    sign_in_as users(:manager)

    post accept_import_review_path(@item), params: { review: review_params(expires_on: printed.iso8601) }

    certificate = @item.reload.certificate
    assert_equal printed, certificate.expires_on
    assert certificate.expiry_printed?
  end

  test "accepting the last item goes back to the empty queue" do
    sign_in_as users(:manager)

    post accept_import_review_path(@item), params: { review: review_params }

    assert_redirected_to import_reviews_path
    assert_match(/Nothing else is waiting for review/, flash[:notice])
  end

  test "accept problems re-render the review with the messages and keep the edits" do
    sign_in_as users(:manager)

    assert_no_difference -> { Certificate.count } do
      post accept_import_review_path(@item), params: { review: review_params(crew_member_id: "", certificate_number: "FA-EDITED") }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /Crew member must exist/
    assert_select "input[name=?][value=?]", "review[certificate_number]", "FA-EDITED"
    assert @item.reload.needs_review?
  end

  test "Accept's refusal of an unreadable printed expiry shows on the review screen, and a typed one goes through" do
    @item.update!(extraction: unreadable_expiry_extraction("2027-06"),
      error_message: "The expiration date \"2027-06\" is not a valid YYYY-MM-DD date.")
    sign_in_as users(:manager)

    assert_no_difference -> { Certificate.count } do
      post accept_import_review_path(@item), params: { review: review_params(expires_on: "") }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /could not be read\. Type the expiry date from the card\./
    assert_select "input[type=date][name=?][required]", "review[expires_on]"
    assert @item.reload.needs_review?

    typed = Date.current + 200
    post accept_import_review_path(@item), params: { review: review_params(expires_on: typed.iso8601) }
    certificate = @item.reload.certificate
    assert_equal typed, certificate.expires_on
    assert certificate.expiry_manual?
  end

  test "accept with a completion date in the future is refused" do
    sign_in_as users(:manager)

    post accept_import_review_path(@item), params: { review: review_params(completed_on: (Date.current + 3).iso8601) }

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /can't be in the future/
  end

  # --- update ---

  test "update saves edits without accepting" do
    flagger = certificate_types(:flagger)
    sign_in_as users(:manager)

    assert_no_difference -> { Certificate.count } do
      patch import_review_path(@item), params: { review: review_params(certificate_type_id: flagger.id, expires_on: "") }
    end

    assert_redirected_to import_review_path(@item)
    @item.reload
    assert @item.needs_review?
    assert_equal @juan, @item.matched_crew_member
    assert @item.person_picked?, "a person picked by hand is not the matcher's proposal"
    assert_equal flagger, @item.matched_certificate_type
    assert @item.type_matched?, "a type picked by hand counts as matched"
    assert_equal Date.current - 20, @item.proposed_completed_on
    assert_equal Date.current - 20 + 36.months, @item.proposed_expires_on
    assert @item.proposed_expiry_computed?
    assert_equal "FA-77001", @item.proposed_certificate_number
    assert_equal "Example Safety Training LLC", @item.issuer_raw
  end

  test "a pick saved by hand shows as picked by hand, and the matcher's own proposal keeps its verdict" do
    @item.update!(matched_crew_member: @juan, person_match: :suggested, type_match: :suggested,
      person_suggestions: [ { "id" => @juan.id, "name" => "Juan Ortiz", "similarity" => 0.7 } ])
    sign_in_as users(:manager)

    patch import_review_path(@item), params: { review: review_params(certificate_number: "FA-1") }
    @item.reload
    assert @item.person_suggested?, "saving the matcher's suggestion unchanged keeps it a suggestion"
    assert @item.type_suggested?

    patch import_review_path(@item), params: { review: review_params(crew_member_id: crew_members(:li_chen).id) }
    get import_review_path(@item)

    assert_select "[data-match=picked]", text: "Picked by hand", count: 1
    assert_select "[data-match=suggested]", text: "Suggested", count: 1 # the type
    get import_reviews_path
    assert_select "#review_items tr##{ActionView::RecordIdentifier.dom_id(@item)} [data-match=picked]", text: "Picked by hand"
  end

  test "Save edits with a hand-picked person, then Accept, teaches that person nothing" do
    li = crew_members(:li_chen)
    sign_in_as users(:manager) # the item: holder "Jaun Ortis", nobody proposed

    patch import_review_path(@item), params: { review: review_params(crew_member_id: li.id) }
    post accept_import_review_path(@item), params: { review: review_params(crew_member_id: li.id) }

    assert_equal li, @item.reload.certificate.crew_member
    assert_not_includes li.reload.name_aliases, "Jaun Ortis"
  end

  test "Save edits keeps the matcher's suggestion, so accepting it still learns the spelling" do
    @item.update!(matched_crew_member: @juan, person_match: :suggested,
      person_suggestions: [ { "id" => @juan.id, "name" => "Juan Ortiz", "similarity" => 0.7 } ])
    sign_in_as users(:manager)

    patch import_review_path(@item), params: { review: review_params }
    post accept_import_review_path(@item), params: { review: review_params }

    assert_includes @juan.reload.name_aliases, "Jaun Ortis"
  end

  test "Save edits with a typed expiry, then Accept, records the expiry as manual" do
    typed = Date.current + 300
    sign_in_as users(:manager)

    patch import_review_path(@item), params: { review: review_params(expires_on: typed.iso8601) }
    assert @item.reload.proposed_expiry_manual?
    get import_review_path(@item)
    assert_select "input[type=date][name=?][value=?]", "review[expires_on]", typed.iso8601
    assert_select "#review_raw", /Typed in by a reviewer/

    post accept_import_review_path(@item), params: { review: review_params(expires_on: typed.iso8601) }

    certificate = @item.reload.certificate
    assert_equal typed, certificate.expires_on
    assert certificate.expiry_manual?
  end

  test "Save edits with an expiry other than the printed one saves it as manual" do
    printed = Date.current + 400
    @item.update!(proposed_expires_on: printed, proposed_expires_on_source: :printed)
    sign_in_as users(:manager)

    patch import_review_path(@item), params: { review: review_params(expires_on: (printed + 30).iso8601) }

    @item.reload
    assert_equal printed + 30, @item.proposed_expires_on
    assert @item.proposed_expiry_manual?
  end

  test "Save edits with the person cleared saves nobody, unmatched" do
    @item.update!(matched_crew_member: @juan, person_match: :suggested)
    sign_in_as users(:manager)

    patch import_review_path(@item), params: { review: review_params(crew_member_id: "") }

    @item.reload
    assert_nil @item.matched_crew_member
    assert @item.person_unmatched?
  end

  test "Save edits with the printed expiry untouched keeps it printed" do
    printed = Date.current + 400
    @item.update!(proposed_expires_on: printed, proposed_expires_on_source: :printed)
    sign_in_as users(:manager)

    patch import_review_path(@item), params: { review: review_params(expires_on: printed.iso8601) }
    assert @item.reload.proposed_expiry_printed?
    post accept_import_review_path(@item), params: { review: review_params(expires_on: printed.iso8601) }

    assert @item.reload.certificate.expiry_printed?
  end

  test "show says why the pipeline held the item, until the reviewer saves new dates" do
    @item.update!(error_message: "The completion date 2030-01-01 is in the future.")
    sign_in_as users(:manager)

    get import_review_path(@item)
    assert_select "#review_pipeline_problem[role=alert]", "Check before accepting: The completion date 2030-01-01 is in the future."
    get import_path(@item.import_batch_id)
    assert_select "#import_items", /Check before accepting: The completion date 2030-01-01 is in the future\./

    patch import_review_path(@item), params: { review: review_params }
    assert_nil @item.reload.error_message
    get import_review_path(@item)
    assert_select "#review_pipeline_problem", count: 0
  end

  test "update refuses impossible dates" do
    sign_in_as users(:manager)

    patch import_review_path(@item), params: { review: review_params(expires_on: (Date.current - 400).iso8601) }

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /before the completion date/
    assert_nil @item.reload.matched_crew_member
  end

  # --- reject and skip ---

  test "reject records the reason and moves on" do
    following = new_item(original_filename: "next.pdf")
    sign_in_as users(:manager)

    post reject_import_review_path(@item), params: { reject: { reason: "Not one of our crew" } }

    assert_redirected_to import_review_path(following)
    assert_equal "Rejected scan_0001.pdf p. 2.", flash[:notice]
    @item.reload
    assert @item.rejected?
    assert_equal "Not one of our crew", @item.rejection_reason
    assert_equal users(:manager), @item.reviewed_by
  end

  test "reject without a reason" do
    sign_in_as users(:manager)

    post reject_import_review_path(@item), params: { reject: { reason: "" } }

    assert @item.reload.rejected?
    assert_equal Imports::Reject::DEFAULT_REASON, @item.rejection_reason
    assert_redirected_to import_reviews_path
  end

  test "skip moves the item to the end of the queue" do
    second = new_item(original_filename: "second.pdf")
    third = new_item(original_filename: "third.pdf")
    sign_in_as users(:manager)

    post skip_import_review_path(@item)

    assert_redirected_to import_review_path(second)
    assert @item.reload.needs_review?
    assert_not_nil @item.skipped_at
    assert_equal [ second, third, @item ], ImportItem.review_queue.to_a

    get import_reviews_path
    assert_equal [ second, third, @item ].map { |item| "import_item_#{item.id}" }, css_select("#review_items tbody tr").map { |row| row["id"] }

    # Skipping the last unskipped item goes on to the next one in queue order: the earliest skipped.
    post skip_import_review_path(second)
    assert_redirected_to import_review_path(third)
    post skip_import_review_path(third)
    assert_redirected_to import_review_path(@item)
    get import_review_path(@item)
    assert_select "#review_position", "Item 1 of 3 waiting"
  end

  test "skipping the only item goes back to the queue" do
    sign_in_as users(:manager)

    post skip_import_review_path(@item)

    assert_redirected_to import_reviews_path
    assert_match(/Nothing else is waiting/, flash[:notice])
  end

  # --- create crew member ---

  test "create crew member adds them and returns to the item with them picked" do
    sign_in_as users(:manager)

    assert_difference -> { CrewMember.count }, 1 do
      post create_crew_member_import_review_path(@item),
        params: { crew_member: { first_name: "Jaun", last_name: "Ortis", employer: "Skyline Tower Services", crew_role_id: crew_roles(:foreman).id } }
    end

    member = CrewMember.order(:id).last
    assert_redirected_to import_review_path(@item)
    assert_equal "Added Jaun Ortis to the crew and picked them for this certificate.", flash[:notice]
    assert_equal "Skyline Tower Services", member.employer
    assert_equal crew_roles(:foreman), member.crew_role
    @item.reload
    assert_equal member, @item.matched_crew_member
    assert @item.person_matched?
    assert @item.needs_review?

    follow_redirect!
    assert_select "select[name=?] option[value=?][selected]", "review[crew_member_id]", member.id.to_s
  end

  test "an item matched to someone warns before creating a second person, and needs a deliberate confirm" do
    @item.update!(holder_name_raw: "Juan Ortiz", matched_crew_member: @juan, person_match: :matched)
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "details#new_crew_member:not([open])" do
      assert_select "#crew_member_duplicate_warning", /Juan Ortiz is already on the crew list\.\s+Create another person anyway\?/
      assert_select "#crew_member_duplicate_warning a[href=?]", crew_member_path(@juan), text: "Juan Ortiz"
      assert_select "input[type=checkbox][name=confirm_duplicate][value='1'][required]"
    end

    assert_no_difference -> { CrewMember.count } do
      post create_crew_member_import_review_path(@item), params: { crew_member: { first_name: "Juan", last_name: "Ortiz" } }
    end
    assert_response :unprocessable_entity
    assert_select "details#new_crew_member[open] #crew_member_errors", /Juan Ortiz is already on the crew list/
    assert_select "input[name=?][value=?]", "crew_member[first_name]", "Juan"

    assert_difference -> { CrewMember.count }, 1 do
      post create_crew_member_import_review_path(@item),
        params: { crew_member: { first_name: "Juan", last_name: "Ortiz" }, confirm_duplicate: "1" }
    end
    assert_redirected_to import_review_path(@item)
    assert_not_equal @juan, @item.reload.matched_crew_member
  end

  test "a person picked by hand, or a name already on the crew list, also needs the confirm" do
    li = crew_members(:li_chen)
    @item.update!(matched_crew_member: li, person_match: :picked)
    sign_in_as users(:manager)

    get import_review_path(@item) # the card says "Jaun Ortis"; Li Chen was picked by hand
    assert_select "#crew_member_duplicate_warning", /Li Chen is already on the crew list/

    @item.update!(matched_crew_member: nil, person_match: :unmatched, holder_name_raw: "ORTIZ, JUAN A.")
    get import_review_path(@item) # nobody matched when the card was read, but the name is on the list now
    assert_select "#crew_member_duplicate_warning", /Juan Ortiz is already on the crew list/

    assert_no_difference -> { CrewMember.count } do # a typed name is checked too, against preferred names and aliases
      post create_crew_member_import_review_path(@item), params: { crew_member: { first_name: "Jon", last_name: "Ortiz" } }
    end
    assert_select "#crew_member_errors", /Juan Ortiz is already on the crew list/

    @item.update!(holder_name_raw: "Jaun Ortis")
    get import_review_path(@item)
    assert_select "#crew_member_duplicate_warning", count: 0
    assert_select "input[name=confirm_duplicate]", count: 0
  end

  test "an inactive crew member with the same name needs the confirm too, and the warning links to their page to reactivate them" do
    sam = crew_members(:sam_inactive)
    @item.update!(holder_name_raw: "Sam Price")
    sign_in_as users(:manager)

    get import_review_path(@item)
    assert_select "#crew_member_duplicate_warning" do
      assert_select "p", /\ASam Price is on the crew list but inactive \(reactivate them from their crew page\)\.\s+Create another person anyway\?\z/
      assert_select "a[href=?][target=_blank]", crew_member_path(sam), text: "Sam Price"
      assert_select "input[type=checkbox][name=confirm_duplicate][value='1'][required]"
    end

    assert_no_difference -> { CrewMember.count } do
      post create_crew_member_import_review_path(@item), params: { crew_member: { first_name: "Sam", last_name: "Price" } }
    end
    assert_response :unprocessable_entity
    assert_select "#crew_member_errors li", "Sam Price is on the crew list but inactive (reactivate them from their crew page). " \
      "Tick \"Yes, this is someone else\" to add another person anyway."

    assert_difference -> { CrewMember.count }, 1 do
      post create_crew_member_import_review_path(@item), params: { crew_member: { first_name: "Sam", last_name: "Price" }, confirm_duplicate: "1" }
    end
    assert_redirected_to import_review_path(@item)
  end

  test "the warning tells active and inactive members with the name apart" do
    CrewMember.create!(first_name: "Sam", last_name: "Price", employer: "Skyline Tower Services")
    @item.update!(holder_name_raw: "Sam Price")
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "#crew_member_duplicate_warning p", /\ASam Price is already on the crew list\. Sam Price is on the crew list but inactive/
    assert_select "#crew_member_duplicate_warning a", count: 2
  end

  test "create crew member errors re-render with the messages" do
    sign_in_as users(:manager)

    assert_no_difference -> { CrewMember.count } do
      post create_crew_member_import_review_path(@item), params: { crew_member: { first_name: "Jaun", last_name: "" } }
    end

    assert_response :unprocessable_entity
    assert_select "details#new_crew_member[open] #crew_member_errors", /Last name can't be blank/
    assert_select "input[name=?][value=?]", "crew_member[first_name]", "Jaun"
    assert_nil @item.reload.matched_crew_member
  end

  # --- merge ---

  test "merge makes one certificate from the front and back of a card" do
    @item.update!(matched_crew_member: @juan, person_match: :matched, proposed_certificate_number: "FA-77001")
    back = new_item(original_filename: "back.jpg", page_range: nil, matched_crew_member: @juan, person_match: :matched,
      matched_certificate_type: @first_aid, type_match: :matched, proposed_certificate_number: "FA-77001")
    back.file.attach(blob("certificate.jpg"))
    sign_in_as users(:manager)

    get import_review_path(@item)
    assert_select "#merge_candidates" do
      assert_select "a[href=?]", import_review_path(back), text: "back.jpg"
      assert_select "button#merge_button[formaction=?]", merge_import_review_path(@item),
        text: "Merge with 1 matching item (front/back of one card)"
    end
    assert_select "form#review_form input[type=hidden][name='other_ids[]'][value=?]", back.id.to_s

    assert_difference -> { Certificate.count }, 1 do
      post merge_import_review_path(@item), params: { review: review_params, other_ids: [ back.id ] }
    end

    certificate = @item.reload.certificate
    assert_redirected_to import_reviews_path
    assert_match(/Merged 2 files into one First Aid\/CPR\/AED certificate for Juan Ortiz/, flash[:notice])
    assert_equal certificate, back.reload.certificate
    assert @item.accepted?
    assert back.accepted?
    assert_equal [ @item.file.blob, back.file.blob ].map(&:id).sort, certificate.files.map(&:blob_id).sort
  end

  test "merge with nothing left to merge re-renders" do
    sign_in_as users(:manager)

    assert_no_difference -> { Certificate.count } do
      post merge_import_review_path(@item), params: { review: review_params, other_ids: [ import_items(:accepted_li_flagger).id ] }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /nothing left to merge/
  end

  # --- read again ---

  test "the review screen offers Read again, asking first, when Imports::Reread allows it" do
    sign_in_as users(:manager)

    allowing_reread(true) { get import_review_path(@item) }
    assert_select "#review_reread form[action=?][method=post]", reread_import_review_path(@item) do |forms|
      assert_match(/uses part of today's free AI allocation\. What it read before, and any edits or rejection, are cleared\./,
        forms.first["data-turbo-confirm"])
      assert_select "button", "Read again"
    end

    allowing_reread(false) { get import_review_path(@item) }
    assert_select "#review_reread", count: 0
  end

  test "Read again hands the item to Imports::Reread and opens its batch" do
    sign_in_as users(:manager)

    calls = stub_reread { post reread_import_review_path(@item) }

    assert_equal [ [ @item.id, users(:manager) ] ], calls
    assert_redirected_to import_path(@item.import_batch_id)
    assert_equal "Reading scan_0001.pdf again.", flash[:notice]
  end

  test "Read again on a failed whole file starts the pipeline over and opens the batch" do
    failed = new_item(status: :failed, original_filename: "broken.pdf", page_range: nil, error_message: "pdftotext timed out")
    failed.file.attach(blob("certificate.pdf"))
    sign_in_as users(:manager)

    assert_enqueued_with(job: Imports::ExtractTextJob, args: [ failed ]) do
      post reread_import_review_path(failed)
    end

    assert_redirected_to import_path(failed.import_batch_id)
    assert_equal "Reading broken.pdf again.", flash[:notice]
    failed.reload
    assert failed.pending?
    assert_nil failed.error_message
  end

  test "Read again that Imports::Reread refuses changes nothing and says why" do
    accepted = import_items(:accepted_li_flagger)
    sign_in_as users(:manager)

    assert_no_enqueued_jobs only: Imports::ExtractTextJob do
      post reread_import_review_path(accepted), headers: { "HTTP_REFERER" => import_url(accepted.import_batch_id) }
    end

    assert_redirected_to import_url(accepted.import_batch_id)
    assert_equal "Accepted items can't be read again.", flash[:alert]
    assert accepted.reload.accepted?
  end

  test "Read again takes items that left the queue (the batch page offers it for rejected and failed ones)" do
    failed = new_item(status: :failed, original_filename: "broken.pdf", page_range: nil, error_message: "pdftotext timed out")
    sign_in_as users(:manager)

    calls = stub_reread { post reread_import_review_path(failed) }

    assert_equal [ [ failed.id, users(:manager) ] ], calls
    assert_redirected_to import_path(failed.import_batch_id)
    assert_equal "Reading broken.pdf again.", flash[:notice]
  end

  test "Read again refused goes back with the reason" do
    sign_in_as users(:manager)
    refusal = Imports::Reread::NotAllowed.new("Today's AI allocation is used up. Read it again after 00:05 UTC.")

    stub_reread(error: refusal) do
      post reread_import_review_path(@item), headers: { "HTTP_REFERER" => import_review_url(@item) }
    end
    assert_redirected_to import_review_url(@item)
    assert_equal "Today's AI allocation is used up. Read it again after 00:05 UTC.", flash[:alert]

    stub_reread(error: refusal) { post reread_import_review_path(@item) } # no referrer: the batch page
    assert_redirected_to import_path(@item.import_batch_id)
  end

  private
    # Imports::Reread.new records [item id, user] and returns a reread whose call does nothing
    # (or raises error). Returns the recorded calls.
    def stub_reread(error: nil)
      calls = []
      Imports::Reread.define_singleton_method(:new) do |item, user:|
        calls << [ item.id, user ]
        Struct.new(:item) { define_method(:call) { error ? raise(error) : item } }.new(item)
      end
      yield
      calls
    ensure
      Imports::Reread.singleton_class.remove_method(:new)
    end

    def allowing_reread(allowed)
      original = Imports::Reread.method(:allowed?)
      Imports::Reread.define_singleton_method(:allowed?) { |_item| allowed }
      yield
    ensure
      Imports::Reread.define_singleton_method(:allowed?, original)
    end

    # The item's extraction when the AI saw an expiry on the card but could not read it as a date.
    def unreadable_expiry_extraction(printed)
      { "certificates" => [ { "pages" => [ 2 ], "holder_name" => "Jaun Ortis", "expires_on" => nil, "unreadable" => { "expires_on" => printed } } ],
        "non_certificate_pages" => [] }
    end

    def review_params(**overrides)
      { crew_member_id: @juan.id, certificate_type_id: @first_aid.id, completed_on: @item.proposed_completed_on.iso8601,
        expires_on: "", certificate_number: "FA-77001", issued_by: "Example Safety Training LLC" }.merge(overrides)
    end

    def new_item(status: :needs_review, **attributes)
      ImportItem.create!({ import_batch: import_batches(:march_batch), status: status, sha256: SecureRandom.hex(32),
        original_filename: "card.pdf", page_range: "1" }.merge(attributes))
    end

    def blob(name)
      ActiveStorage::Blob.create_and_upload!(io: file_fixture(name).open, filename: name)
    end

    def format_date(date)
      date.strftime("%b %-d, %Y")
    end
end
