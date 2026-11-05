require "test_helper"

class AuthenticityChecksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @juan = crew_members(:juan_ortiz)
    @certificate = certificates(:juan_first_aid)
    @item = import_items(:review_juan_first_aid)
    @issuer = CertificateIssuer.create!(name: "Summit Safety Training", code: "SUMMIT", domains: [ "summitsafety.org" ],
      verification_method: :qr_or_code, lookup_url: "https://verify.summitsafety.org/", verification_notes: "Enter the ID.")
  end

  # --- Access ---

  test "viewers can't record a result or check again" do
    sign_in_as users(:viewer)

    patch crew_member_certificate_authenticity_path(@juan, @certificate), params: { authenticity: { status: "verified" } }
    assert_response :forbidden
    post recheck_crew_member_certificate_authenticity_path(@juan, @certificate)
    assert_response :forbidden
    patch import_review_authenticity_path(@item), params: { authenticity: { status: "verified" } }
    assert_response :forbidden
    post recheck_import_review_authenticity_path(@item)
    assert_response :forbidden

    assert @certificate.reload.authenticity_unchecked?
    assert @item.reload.authenticity_unchecked?
    assert_no_enqueued_jobs only: Verification::CheckJob
  end

  test "anonymous users are sent to sign in" do
    patch crew_member_certificate_authenticity_path(@juan, @certificate), params: { authenticity: { status: "verified" } }
    assert_redirected_to new_session_path
  end

  # --- Recording a result ---

  test "a manager records a result with a note on a certificate" do
    certificates(:juan_first_aid_old).destroy!
    sign_in_as users(:manager)

    freeze_time do
      patch crew_member_certificate_authenticity_path(@juan, @certificate),
        params: { authenticity: { status: "not_found", note: "  The issuer's page says no such certificate.  " } }

      assert_redirected_to crew_member_certificate_path(@juan, @certificate, anchor: "authenticity")
      assert_equal "Recorded “Not found by issuer”. It is now confirmed fake: it counts as not valid in compliance and is left out " \
        "of packets. Automatic checks won't change it unless someone runs Check again.", flash[:notice]
      @certificate.reload
      assert @certificate.authenticity_not_found?
      assert @certificate.authenticity_set_by_person?
      assert_equal "The issuer's page says no such certificate.", @certificate.authenticity_note
      assert_equal users(:manager), @certificate.authenticity_checked_by
      assert_equal Time.current, @certificate.authenticity_checked_at
      assert_equal [ "checked_inputs" ], @certificate.authenticity_details.keys, "the digests of what was checked, nothing else"
    end
    assert @certificate.authenticity_confirmed_fake?
    assert_equal "fake", @certificate.compliance_status
  end

  test "a result that isn't fake says nothing about it, and replaces a confirmed fake one" do
    @certificate.record_authenticity!(status: :mismatch, method: "person", by: users(:admin))
    sign_in_as users(:manager)

    patch crew_member_certificate_authenticity_path(@juan, @certificate), params: { authenticity: { status: "verified" } }

    assert_equal "Recorded “Verified”. Automatic checks won't change it unless someone runs Check again.", flash[:notice]
    assert_not @certificate.reload.authenticity_confirmed_fake?
    assert @certificate.current?, "no longer fake, so the newest is current again"
    assert_equal "lapses_on_project", @certificate.compliance_status(project_ends_on: projects(:tower_2417).ends_on)
  end

  test "Not found on a certificate with an older genuine one on file says the older one is current now" do
    sign_in_as users(:manager)

    patch crew_member_certificate_authenticity_path(@juan, @certificate), params: { authenticity: { status: "not_found" } }

    assert_equal "Recorded “Not found by issuer”. It is now confirmed fake and kept as history: another First Aid/CPR/AED " \
      "certificate on file is the current one. Automatic checks won't change it unless someone runs Check again.", flash[:notice]
    assert @certificate.reload.superseded?
    assert_equal certificates(:juan_first_aid_old), @juan.current_certificate_for(@certificate.certificate_type)

    follow_redirect!
    assert_select "#superseded_notice", /Confirmed fake, so another First Aid\/CPR\/AED certificate on file is the current one/
    assert_select "#superseded_notice", text: /by a newer/, count: 0
  end

  test "a person's Not found on an import item is confirmed fake once it is accepted" do
    sign_in_as users(:manager)

    patch import_review_authenticity_path(@item), params: { authenticity: { status: "mismatch" } }

    assert_equal "Recorded “Doesn't match issuer”. It is now confirmed fake: once accepted, it counts as not valid in compliance " \
      "and is left out of packets. Automatic checks won't change it unless someone runs Check again.", flash[:notice]
    assert @item.reload.authenticity_confirmed_fake?
  end

  test "an admin records every person result on an import item, note optional" do
    sign_in_as users(:admin)

    Authenticity::PERSON_STATUSES.each do |status|
      patch import_review_authenticity_path(@item), params: { authenticity: { status: status, note: "" } }

      assert_redirected_to import_review_path(@item, anchor: "authenticity")
      @item.reload
      assert_equal status, @item.authenticity_status
      assert_nil @item.authenticity_note
      assert_equal users(:admin), @item.authenticity_checked_by
    end
    assert @item.needs_review?, "recording a result doesn't review the item"
  end

  test "a long note is cut to the limit" do
    sign_in_as users(:manager)

    patch crew_member_certificate_authenticity_path(@juan, @certificate),
      params: { authenticity: { status: "verified", note: "a" * (AuthenticityChecksController::NOTE_LIMIT + 50) } }

    assert_equal AuthenticityChecksController::NOTE_LIMIT, @certificate.reload.authenticity_note.size
  end

  test "statuses a person can't record are refused" do
    sign_in_as users(:manager)

    %w[suspicious needs_check unchecked bogus].each do |status|
      patch crew_member_certificate_authenticity_path(@juan, @certificate), params: { authenticity: { status: status } }

      assert_redirected_to crew_member_certificate_path(@juan, @certificate, anchor: "authenticity")
      assert_equal "Choose one of the result buttons to record a check.", flash[:alert]
    end
    assert @certificate.reload.authenticity_unchecked?

    patch crew_member_certificate_authenticity_path(@juan, @certificate), params: { note: "no result" }
    assert_response :bad_request
  end

  test "certificates are scoped to their crew member" do
    sign_in_as users(:manager)

    patch crew_member_certificate_authenticity_path(crew_members(:maria_garcia), @certificate), params: { authenticity: { status: "verified" } }

    assert_response :not_found
    assert @certificate.reload.authenticity_unchecked?
  end

  test "an import item that is no longer waiting for review can't be changed" do
    @item.update!(status: :rejected)
    sign_in_as users(:manager)

    patch import_review_authenticity_path(@item), params: { authenticity: { status: "verified" } }
    assert_redirected_to import_path(@item.import_batch_id)
    assert_match(/no longer waiting for review/, flash[:alert])
    post recheck_import_review_authenticity_path(@item)
    assert_redirected_to import_path(@item.import_batch_id)

    assert @item.reload.authenticity_unchecked?
    assert_no_enqueued_jobs only: Verification::CheckJob
  end

  # --- Check again ---

  test "check again queues a forced check of a certificate, with when it was pressed" do
    sign_in_as users(:manager)
    freeze_time

    assert_enqueued_with(job: Verification::CheckJob, args: [ @certificate, { force: true, requested_at: Time.current } ]) do
      post recheck_crew_member_certificate_authenticity_path(@juan, @certificate)
    end
    assert_redirected_to crew_member_certificate_path(@juan, @certificate, anchor: "authenticity")
    assert_match(/Checking again/, flash[:notice])
  end

  test "check again queues a forced check of an import item" do
    sign_in_as users(:admin)
    freeze_time

    assert_enqueued_with(job: Verification::CheckJob, args: [ @item, { force: true, requested_at: Time.current } ]) do
      post recheck_import_review_authenticity_path(@item)
    end
    assert_redirected_to import_review_path(@item, anchor: "authenticity")
  end

  test "check again replaces a person's result once the job runs" do
    @certificate.update!(certificate_issuer: @issuer, verification_code: "SUM-1001")
    @certificate.record_authenticity!(status: :verified, method: "person", note: "Looked it up", by: users(:manager))
    sign_in_as users(:manager)

    perform_enqueued_jobs(only: Verification::CheckJob) do
      post recheck_crew_member_certificate_authenticity_path(@juan, @certificate)
    end

    @certificate.reload
    assert_not @certificate.authenticity_set_by_person?
    assert @certificate.authenticity_needs_check?, "an assisted issuer with a code needs a person's check"
    assert_nil @certificate.authenticity_checked_by
  end

  # The page's "Check again" form says when the page was shown.
  def shown_at_on_page
    css_select("form#authenticity_recheck input[name='authenticity[shown_at]']").sole["value"]
  end

  test "check again from a page shown before someone recorded Not found leaves their result alone, and says so" do
    @certificate.update!(certificate_issuer: @issuer, verification_code: "SUM-1001")
    Verification::Run.new(@certificate, network: false).call
    sign_in_as users(:manager)
    get crew_member_certificate_path(@juan, @certificate) # an automatic needs_check: nothing to confirm
    shown_at = shown_at_on_page
    travel 30.seconds
    Certificate.find(@certificate.id).record_authenticity!(status: :not_found, method: "person", note: "Called Summit", by: users(:admin))
    travel 15.seconds

    perform_enqueued_jobs(only: Verification::CheckJob) do
      post recheck_crew_member_certificate_authenticity_path(@juan, @certificate), params: { authenticity: { shown_at: shown_at } }
    end

    assert_redirected_to crew_member_certificate_path(@juan, @certificate, anchor: "authenticity")
    assert_equal "Someone recorded “Not found by issuer” after this page was opened, so it wasn't checked again. " \
      "Reload the page to see it.", flash[:alert]
    assert @certificate.reload.authenticity_confirmed_fake?, "the admin's result, which the manager never saw, stays"
    assert_equal "fake", @certificate.compliance_status
  end

  test "check again from a page that showed the person's result replaces it" do
    @certificate.update!(certificate_issuer: @issuer, verification_code: "SUM-1001")
    @certificate.record_authenticity!(status: :not_found, method: "person", by: users(:admin))
    sign_in_as users(:manager)
    get crew_member_certificate_path(@juan, @certificate)
    shown_at = shown_at_on_page
    assert_in_delta Time.current, Time.zone.iso8601(shown_at), 1.second
    travel 15.seconds

    assert_enqueued_with(job: Verification::CheckJob, args: [ @certificate, { force: true, requested_at: Time.zone.iso8601(shown_at) } ]) do
      post recheck_crew_member_certificate_authenticity_path(@juan, @certificate), params: { authenticity: { shown_at: shown_at } }
    end
    perform_enqueued_jobs(only: Verification::CheckJob)
    assert_equal [ "needs_check", "rules" ], [ @certificate.reload.authenticity_status, @certificate.authenticity_method ]
  end

  test "a shown_at in the future or not a time counts as now" do
    freeze_time
    assert_equal Time.current, AuthenticityChecksController.recheck_requested_at((Time.current + 1.day).iso8601(6))
    assert_equal Time.current, AuthenticityChecksController.recheck_requested_at("yesterday-ish")
    assert_equal Time.current, AuthenticityChecksController.recheck_requested_at(nil)
    assert_equal 1.minute.ago, AuthenticityChecksController.recheck_requested_at(1.minute.ago.iso8601(6))
  end

  # --- The panel ---

  test "the certificate panel shows the status, note, who checked, the link and the buttons to editors" do
    @certificate.update!(certificate_issuer: @issuer, verification_code: "SUM-1001",
      verification_url: "https://verify.summitsafety.org/c/SUM-1001")
    @certificate.record_authenticity!(status: :verified, method: "person", note: "Matches the issuer's page", by: users(:admin))
    sign_in_as users(:manager)

    get crew_member_certificate_path(@juan, @certificate)

    assert_response :success
    assert_select "#authenticity" do
      assert_select "#authenticity_status [data-authenticity=verified].bg-green-100", "Verified"
      assert_select "#authenticity_note", "Matches the issuer's page"
      assert_select "#authenticity_checked", /Checked by Ada Admin on/
      assert_select "#authenticity_issuer", "Summit Safety Training"
      assert_select "#authenticity_code", "SUM-1001"
      assert_select "a#authenticity_open[href=?][target=_blank][rel=?]", "https://verify.summitsafety.org/c/SUM-1001",
        "noopener noreferrer", text: /Open verification page\s+\(verify\.summitsafety\.org\)/
      assert_select "#authenticity_off_site", count: 0
      assert_select "#authenticity_notes", count: 0 # notes only show without a direct link
      assert_select "form#authenticity_form[action=?]", crew_member_certificate_authenticity_path(@juan, @certificate) do
        assert_select "input[name=_method][value=patch]"
        assert_select "textarea[name=?]", "authenticity[note]"
        assert_equal [ "Verified", "Not found", "Doesn't match", "Can't be verified" ], css_select("button[name='authenticity[status]']").map(&:text)
        assert_equal Authenticity::PERSON_STATUSES.sort, css_select("button[name='authenticity[status]']").map { it["value"] }.sort
        confirm = "Record this certificate as fake? It will count as not valid and be left out of packets."
        assert_equal({ "verified" => nil, "not_found" => confirm, "mismatch" => confirm, "cannot_verify" => nil },
          css_select("button[name='authenticity[status]']").to_h { [ it["value"], it["data-turbo-confirm"] ] })
        assert_select "#authenticity_fake_buttons_hint",
          "Not found and Doesn't match mark it as fake. Use them only after checking with the issuer."
      end
      assert_select "form#authenticity_recheck[action=?][data-turbo-confirm=?]", recheck_crew_member_certificate_authenticity_path(@juan, @certificate),
        "Check again? The automatic result replaces the one a person recorded."
      assert_select "#authenticity_fake_hint", count: 0
      assert_select "#authenticity_flagged_hint", count: 0
    end
  end

  test "viewers see the panel read-only; an automatic check's flag is only flagged for review" do
    @certificate.record_authenticity!(status: :mismatch, method: "automatic:aha_ecards", note: "The issuer shows a different name.")
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, @certificate)

    assert_select "#authenticity.border-red-300" do
      assert_select "[data-authenticity=mismatch].bg-red-600[title=?]", "Flagged for review: Doesn't match issuer", "Doesn't match issuer"
      assert_select "[data-fake]", count: 0
      assert_select "#authenticity_flagged_hint", "Flagged for review. It still counts by its dates and goes in packets until " \
        "someone checks it with the issuer and records the result."
      assert_select "#authenticity_fake_hint", count: 0
      assert_select "#authenticity_fake_reason", count: 0
      assert_select "#authenticity_checked", /Checked automatically on/
      assert_select "form", count: 0
      assert_select "button", count: 0
      assert_select "#authenticity_fake_buttons_hint", count: 0
    end
    assert_equal "lapses_on_project", @certificate.reload.compliance_status(project_ends_on: projects(:tower_2417).ends_on)
  end

  test "a person's Not found or Doesn't match shows the certificate as confirmed fake" do
    @certificate.record_authenticity!(status: :not_found, method: "person", note: "No such certificate on the issuer's page.",
      by: users(:manager))
    sign_in_as users(:manager)

    get crew_member_certificate_path(@juan, @certificate)

    assert_select "#authenticity.border-red-300" do
      assert_select "#authenticity_status [data-authenticity=not_found][data-fake=true].bg-red-800[title=?]",
        "Confirmed fake: Not found by issuer", "Confirmed fake"
      assert_select "#authenticity_fake_reason", "Not found by issuer"
      assert_select "#authenticity_fake_hint", "Confirmed fake: a person checked it with the issuer. It counts as not valid " \
        "in compliance and is left out of packets."
      assert_select "#authenticity_flagged_hint", count: 0
      assert_select "#authenticity_checked", /Checked by Manny Manager/
      assert_select "form#authenticity_recheck[data-turbo-confirm=?]",
        "Check again? The automatic result replaces the one a person recorded, so it is no longer confirmed fake."
    end
  end

  test "a suspicious result saved as a person's is still only flagged for review" do
    # A person can't record suspicious (Authenticity::PERSON_STATUSES), but a row could still say so.
    @certificate.update_columns(authenticity_status: Certificate.authenticity_statuses[:suspicious], authenticity_method: "person")
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, @certificate)

    assert_select "#authenticity.border-red-300" do
      assert_select "[data-authenticity=suspicious][title=?]", "Flagged for review: Suspicious link", "Suspicious link"
      assert_select "[data-fake]", count: 0
      assert_select "#authenticity_flagged_hint", /\AFlagged for review\./
      assert_select "#authenticity_fake_hint", count: 0
    end
  end

  test "without a direct link the panel offers the issuer's lookup page and notes" do
    @certificate.update!(certificate_issuer: @issuer, verification_code: "SUM-1001")
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, @certificate)

    assert_select "#authenticity" do
      assert_select "#authenticity_status", "Not checked yet"
      assert_select "#authenticity_checked", "Not checked yet"
      assert_select "a#authenticity_open", count: 0
      assert_select "a#authenticity_lookup[href=?][target=_blank][rel=?]", "https://verify.summitsafety.org/", "noopener noreferrer",
        text: /Open Summit Safety Training's lookup page/
      assert_select "#authenticity_links", /Type the verification code there/
      assert_select "#authenticity_notes", /Enter the ID\./
    end
  end

  test "a link off the issuer's own website is pointed out, after the issuer's own page; a suspicious one isn't linked" do
    @certificate.update!(certificate_issuer: @issuer, verification_url: "https://records.example-training.com/c/1")
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, @certificate)
    assert_select "#authenticity_links" do
      assert_select "a", 2
      assert_select "a:first-of-type#authenticity_lookup[href=?]", "https://verify.summitsafety.org/"
      assert_select "a#authenticity_open[href=?]", "https://records.example-training.com/c/1"
    end
    assert_select "#authenticity_off_site", /isn't on Summit Safety Training's own website/

    @issuer.update!(link_template: "https://verify.summitsafety.org/c/{code}")
    @certificate.update!(verification_code: "SUM-1")
    get crew_member_certificate_path(@juan, @certificate)
    assert_select "#authenticity_links a:first-of-type#authenticity_issuer_link[href=?]", "https://verify.summitsafety.org/c/SUM-1",
      text: /Open Summit Safety Training's verification page/

    @certificate.record_authenticity!(status: :suspicious, method: "rules", note: "The QR code points to a lookalike website.")
    get crew_member_certificate_path(@juan, @certificate)
    assert_select "a#authenticity_open", count: 0
    assert_select "#authenticity_suspicious_hint", /Don't open this certificate's verification link or QR code/
    assert_select "a#authenticity_issuer_link[href=?]", "https://verify.summitsafety.org/c/SUM-1"
  end

  test "a lookalike or disguised link is warned about and not linked, even before a check flags it, and with no issuer" do
    CertificateIssuer.seed_defaults!
    sign_in_as users(:viewer)

    @certificate.update_columns(verification_url: "https://www.redcross-verify.com/certificate?certnumber=1")
    get crew_member_certificate_path(@juan, @certificate)
    assert_select "#authenticity_issuer", "Not known"
    assert_select "a#authenticity_open", count: 0
    assert_select "a[href*='redcross-verify']", count: 0
    assert_select "#authenticity_link_warning",
      "This link points to redcross-verify.com, which looks like redcross.org but isn't, so it isn't linked here."

    @certificate.update_columns(verification_url: "https://www.redcross.org@verify-now.net/c/1")
    get crew_member_certificate_path(@juan, @certificate)
    assert_select "a[href*='verify-now']", count: 0
    assert_select "#authenticity_link_warning", /is disguised: it opens verify-now\.net/
  end

  test "only https links are rendered, and issuer text is escaped" do
    @issuer.update_columns(lookup_url: "javascript:alert(1)", name: "<script>alert(1)</script>",
      verification_notes: "<img src=x onerror=alert(1)>")
    @certificate.update!(certificate_issuer: @issuer)
    @certificate.update_columns(authenticity_note: "<b>note</b>")
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, @certificate)

    assert_select "a[href^='javascript']", count: 0
    assert_select "#authenticity_lookup", count: 0
    assert_no_match(/<script>alert/, response.body)
    assert_no_match(/<img src=x/, response.body)
    assert_no_match(/<b>note<\/b>/, response.body)
  end

  test "the review screen shows the item's panel; its buttons save the review form's edits first" do
    @item.file.attach(io: file_fixture("certificate.pdf").open, filename: "certificate.pdf")
    @item.update!(matched_certificate_issuer: @issuer, issuer_match: :matched, proposed_verification_code: "SUM-2002")
    @item.record_authenticity!(status: :needs_check, method: "rules", note: "Look the code up on the issuer's page.")
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "#authenticity" do
      assert_select "[data-authenticity=needs_check].bg-amber-100", "Needs a check"
      assert_select "#authenticity_code", "SUM-2002"
      assert_select "#authenticity_issuer_unconfirmed", count: 0
      assert_select "form", count: 0 # the buttons belong to the review form (ImportReviewsController#check)
      assert_select "button[form=review_form][formaction=?]", check_import_review_path(@item), count: 5
      assert_select "button#authenticity_recheck[data-turbo-confirm]", count: 0 # nothing a person recorded to replace
      confirm = "Record this as fake? Once accepted, it will count as not valid and be left out of packets."
      assert_equal({ "verified" => nil, "not_found" => confirm, "mismatch" => confirm, "cannot_verify" => nil },
        css_select("button[name='authenticity[status]'][form=review_form]").to_h { [ it["value"], it["data-turbo-confirm"] ] })
      assert_select "#authenticity_fake_buttons_hint", "Not found and Doesn't match mark it as fake. Use them only after checking with the issuer."
    end
    assert_select "form#review_form #authenticity", count: 0 # not nested in the review form

    @item.record_authenticity!(status: :not_found, method: "automatic:aha_ecards")
    get import_review_path(@item)
    assert_select "#authenticity_flagged_hint", "Flagged for review. Once accepted, it counts by its dates and goes in packets " \
      "until someone checks it with the issuer and records the result."

    @item.record_authenticity!(status: :verified, method: "person", by: users(:admin))
    get import_review_path(@item)
    assert_select "button#authenticity_recheck[data-turbo-confirm]"

    @item.record_authenticity!(status: :mismatch, method: "person", by: users(:admin))
    get import_review_path(@item)
    assert_select "#authenticity [data-authenticity=mismatch][data-fake=true]", "Confirmed fake"
    assert_select "#authenticity_fake_hint", "Confirmed fake: a person checked it with the issuer. Once accepted, it counts as " \
      "not valid in compliance and is left out of packets."
  end

  test "a suggested issuer is marked as not confirmed on the review screen" do
    @item.update!(matched_certificate_issuer: @issuer, issuer_match: :suggested)
    sign_in_as users(:manager)

    get import_review_path(@item)

    assert_select "#authenticity_issuer", "Summit Safety Training"
    assert_select "#authenticity_issuer_unconfirmed", "Suggested, not confirmed."
  end
end
