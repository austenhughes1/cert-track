require "test_helper"

# The default issuers may be in the test database too (db:seed), so assertions look at the
# issuers created here.
class CertificateIssuersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @lookup = CertificateIssuer.create!(name: "Summit Safety Training", code: "SUMMIT", position: 1,
      aliases: [ "Summit Safety", "Summit Safety Training LLC" ], domains: [ "summitsafety.org" ],
      verification_method: :qr_or_code, lookup_url: "https://verify.summitsafety.org/",
      link_template: "https://verify.summitsafety.org/c/{code}", verification_notes: "Scan the QR code.")
    @automatic = CertificateIssuer.create!(name: "Ridgeline CPR", code: "RIDGELINE", position: 2, domains: [ "ridgelinecpr.com" ],
      verification_method: :code_lookup, automatic_check: "aha_ecards")
    @typed = CertificateIssuer.create!(name: "Bob's Training Shack", code: "BOBS") # what "Other..." leaves behind
    @retired = CertificateIssuer.create!(name: "Old Tower School", code: "OLDTOWER", active: false, verification_method: :contact)
  end

  # --- Access ---

  test "anonymous users are sent to sign in" do
    get certificate_issuers_path
    assert_redirected_to new_session_path
  end

  test "managers and viewers get 403 on every action, reads included" do
    %i[manager viewer].each do |role|
      sign_in_as users(role)

      get certificate_issuers_path
      assert_response :forbidden, "#{role} index"
      get new_certificate_issuer_path
      assert_response :forbidden, "#{role} new"
      assert_no_difference -> { CertificateIssuer.count } do
        post certificate_issuers_path, params: { certificate_issuer: { name: "Sneaky", code: "SNEAKY" } }
      end
      assert_response :forbidden, "#{role} create"
      get edit_certificate_issuer_path(@lookup)
      assert_response :forbidden, "#{role} edit"
      patch certificate_issuer_path(@lookup), params: { certificate_issuer: { active: false } }
      assert_response :forbidden, "#{role} update"
      assert_no_difference -> { CertificateIssuer.count } do
        delete certificate_issuer_path(@typed)
      end
      assert_response :forbidden, "#{role} destroy"

      assert @lookup.reload.active?
      sign_out
    end
  end

  test "the nav links admins to the issuers, not managers" do
    sign_in_as @admin
    get root_path
    assert_select "nav a[href=?]", certificate_issuers_path, text: "Issuers"

    sign_in_as users(:manager)
    get root_path
    assert_select "nav a[href=?]", certificate_issuers_path, count: 0
  end

  # --- Index ---

  test "index lists active issuers by position then name with method, check and domains" do
    sign_in_as @admin

    get certificate_issuers_path

    assert_response :success
    assert_select "title", "Issuers · CertTrack"
    mine = [ @lookup, @automatic, @typed, @retired ].map { dom_id(it) }
    assert_equal [ @lookup, @automatic, @typed ].map { dom_id(it) }, css_select("tbody tr").map { it["id"] } & mine
    assert_select "tr##{dom_id(@lookup)}" do
      assert_select "td[data-column=code]", "SUMMIT"
      assert_select "td[data-column=name]", /Summit Safety Training/
      assert_select "td[data-column=name]", /Also: Summit Safety, Summit Safety Training LLC/
      assert_select "td[data-column=method]", "QR code or code lookup"
      assert_select "td[data-column=check]", "A person checks"
      assert_select "td[data-column=domains]", "summitsafety.org"
      assert_select "td[data-column=status]", "Active"
      assert_select "[data-needs-details]", count: 0
      assert_select "a[href=?]", edit_certificate_issuer_path(@lookup)
      assert_select "form[action=?] button", certificate_issuer_path(@lookup), "Deactivate"
      assert_select "form[action=?] input[name=_method][value=delete]", certificate_issuer_path(@lookup) # unused
    end
    assert_select "tr##{dom_id(@automatic)} td[data-column=check]", "AHA eCard lookup"
    assert_select "tr##{dom_id(@retired)}", count: 0
  end

  test "issuers added with Other... are pointed out until their details are filled in" do
    CertificateIssuer.where.not(id: @typed.id).verified_by_unknown.update_all(verification_method: CertificateIssuer.verification_methods[:contact])
    sign_in_as @admin

    get certificate_issuers_path

    assert_select "#needs_details_banner", /1 issuer was added with Other… and needs its verification details/
    assert_select "#needs_details_banner a[href=?]", certificate_issuers_path(status: "needs_details")
    assert_select "tr##{dom_id(@typed)} [data-needs-details]", "Needs details"
    assert_select "tr##{dom_id(@typed)} td[data-column=method]", "Not known yet"

    get certificate_issuers_path(status: "needs_details")
    assert_equal [ dom_id(@typed) ], css_select("tbody tr").map { it["id"] }
    assert_select "#needs_details_banner", count: 0

    get edit_certificate_issuer_path(@typed)
    assert_select "#needs_details_note", /Added with Other… in an issuer picker/

    patch certificate_issuer_path(@typed), params: { certificate_issuer: { verification_method: "contact", domains: "bobstraining.com" } }
    get certificate_issuers_path
    assert_select "#needs_details_banner", count: 0
    assert_select "tr##{dom_id(@typed)} [data-needs-details]", count: 0
  end

  test "status filters show inactive issuers muted, and all together" do
    sign_in_as @admin

    get certificate_issuers_path(status: "inactive")
    assert_select "tbody tr", CertificateIssuer.where(active: false).count
    assert_select "tr##{dom_id(@retired)}.text-gray-400 td[data-column=status]", "Inactive"
    assert_select "tr##{dom_id(@retired)} button", "Reactivate"

    get certificate_issuers_path(status: "all")
    assert_select "tbody tr", CertificateIssuer.count

    get certificate_issuers_path(status: "bogus")
    assert_select "tbody tr", CertificateIssuer.active.count
  end

  test "an issuer in use shows its current certificates and has no delete button" do
    certificates(:juan_first_aid).update!(certificate_issuer: @lookup)
    certificates(:juan_first_aid_old).update!(certificate_issuer: @lookup)
    sign_in_as @admin

    get certificate_issuers_path

    assert_select "tr##{dom_id(@lookup)}" do
      assert_select "td[data-column=current-certificates]", "1"
      assert_select "td[data-column=current-certificates][title=?]", "2 certificates including history"
      assert_select "input[name=_method][value=delete]", count: 0
    end
  end

  test "index shows empty states" do
    sign_in_as @admin

    CertificateIssuer.verified_by_unknown.update_all(verification_method: CertificateIssuer.verification_methods[:contact])
    get certificate_issuers_path(status: "needs_details")
    assert_select "tbody", count: 0
    assert_select "p", "No issuers need details"

    Certificate.update_all(certificate_issuer_id: nil)
    ImportItem.update_all(matched_certificate_issuer_id: nil)
    CertificateIssuer.delete_all
    get certificate_issuers_path
    assert_select "p", "No issuers yet"
  end

  # --- New and create ---

  test "new renders every field" do
    sign_in_as @admin

    get new_certificate_issuer_path

    assert_response :success
    assert_select "form[action=?]", certificate_issuers_path do
      %w[name code domains lookup_url link_template verification_notes aliases position].each do |field|
        assert_select "[name=?]", "certificate_issuer[#{field}]"
      end
      assert_select "select[name=?] option[value=qr_or_code]", "certificate_issuer[verification_method]", "QR code or code lookup"
      assert_select "select[name=?]", "certificate_issuer[automatic_check]" do
        assert_select "option[value='']", "None: a person checks"
        Verification::Checkers::KEYS.each { |key| assert_select "option[value=?]", key }
      end
    end
  end

  test "create splits domains on commas and aliases on lines" do
    sign_in_as @admin

    assert_difference -> { CertificateIssuer.count }, 1 do
      post certificate_issuers_path, params: { certificate_issuer: {
        name: "Peak Rescue", code: "peak", domains: "https://www.peakrescue.com/verify, peakcerts.net\npeakrescue.com",
        aliases: "Peak Rescue, Inc.\r\nPeak", verification_method: "code_lookup", lookup_url: "https://peakrescue.com/verify",
        link_template: "", automatic_check: "", verification_notes: "By certificate number.", active: "1", position: ""
      } }
    end

    issuer = CertificateIssuer.find_by!(code: "PEAK")
    assert_redirected_to certificate_issuers_path
    assert_equal "Added Peak Rescue to the issuers.", flash[:notice]
    assert_equal %w[peakrescue.com peakcerts.net], issuer.domains
    assert_equal [ "Peak Rescue, Inc.", "Peak" ], issuer.aliases
    assert issuer.verified_by_code_lookup?
    assert_nil issuer.link_template
    assert_nil issuer.automatic_check
  end

  test "create problems re-render the form with the messages" do
    sign_in_as @admin

    assert_no_difference -> { CertificateIssuer.count } do
      post certificate_issuers_path, params: { certificate_issuer: {
        name: "Summit Safety Training", code: "bad code", lookup_url: "http://insecure.example.com", automatic_check: "scrape_everything"
      } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation" do
      assert_select "li", /Name has already been taken/
      assert_select "li", /Code may only contain letters, digits, - and _/
      assert_select "li", /Lookup url must start with https:\/\//
      assert_select "li", /Automatic check is not a known checker/
    end
  end

  # --- Edit, update and destroy ---

  test "edit fills in the comma-separated domains and one alias per line" do
    sign_in_as @admin

    get edit_certificate_issuer_path(@lookup)

    assert_response :success
    assert_select "h1", "Edit Summit Safety Training"
    assert_select "p", /Not used by any certificate or import yet/
    assert_select "input[name=?][value=?]", "certificate_issuer[domains]", "summitsafety.org"
    assert_select "textarea[name=?]", "certificate_issuer[aliases]", text: "Summit Safety\nSummit Safety Training LLC"
    assert_select "#danger_zone button", "Delete"
  end

  test "update saves and a list button returns to the same filter" do
    sign_in_as @admin

    patch certificate_issuer_path(@lookup), params: { certificate_issuer: { verification_notes: "Call them.", position: "5" } }
    assert_redirected_to certificate_issuers_path
    assert_equal "Saved Summit Safety Training.", flash[:notice]
    assert_equal [ "Call them.", 5 ], [ @lookup.reload.verification_notes, @lookup.position ]

    patch certificate_issuer_path(@lookup), params: { certificate_issuer: { active: false }, status: "needs_details" }
    assert_redirected_to certificate_issuers_path(status: "needs_details")
    assert_match(/Deactivated Summit Safety Training/, flash[:notice])

    patch certificate_issuer_path(@retired), params: { certificate_issuer: { active: true } }
    assert_equal "Reactivated Old Tower School.", flash[:notice]
  end

  test "update problems re-render the edit page" do
    sign_in_as @admin

    patch certificate_issuer_path(@lookup), params: { certificate_issuer: { name: "", link_template: "https://x.example.com/no-code" } }

    assert_response :unprocessable_entity
    assert_select "h1", "Edit Summit Safety Training"
    assert_select "#error_explanation li", /Link template must start with https:\/\/ and contain \{code\}/
  end

  test "destroy deletes an unused issuer" do
    sign_in_as @admin

    assert_difference -> { CertificateIssuer.count }, -1 do
      delete certificate_issuer_path(@typed)
    end
    assert_redirected_to certificate_issuers_path
    assert_equal "Deleted Bob's Training Shack.", flash[:notice]
  end

  test "destroy deactivates an issuer that certificates or import items use" do
    certificates(:juan_first_aid).update!(certificate_issuer: @lookup)
    import_items(:review_juan_first_aid).update!(matched_certificate_issuer: @automatic)
    sign_in_as @admin

    get edit_certificate_issuer_path(@lookup)
    assert_select "#danger_zone h2", "Deactivate this issuer"
    assert_select "#danger_zone", /used by 1 certificate/

    assert_no_difference -> { CertificateIssuer.count } do
      delete certificate_issuer_path(@lookup)
      delete certificate_issuer_path(@automatic)
    end
    assert_not @lookup.reload.active?
    assert_not @automatic.reload.active?
    assert_match(/used by 1 import item, so it can't be deleted\. It was deactivated instead/, flash[:notice])
    assert_equal @lookup, certificates(:juan_first_aid).reload.certificate_issuer

    delete certificate_issuer_path(@lookup)
    assert_match(/It's already inactive/, flash[:alert])
  end

  test "issuer text is escaped on every page" do
    @typed.update!(name: "<script>alert(1)</script> Training", aliases: [ "<b>bold</b>" ], verification_notes: "<img src=x onerror=alert(1)>")
    sign_in_as @admin

    get certificate_issuers_path
    assert_no_match(/<script>alert/, response.body)
    assert_no_match(/<b>bold<\/b>/, response.body)
    get edit_certificate_issuer_path(@typed)
    assert_no_match(/<script>alert/, response.body)
    assert_no_match(/<img src=x/, response.body)
  end
end
