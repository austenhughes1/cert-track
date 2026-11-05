require "test_helper"

class CertificateTypesControllerTest < ActionDispatch::IntegrationTest
  setup { @admin = users(:admin) }

  # --- Access ---

  test "a new type starts at the 2-year default; blanking it is how a type never expires" do
    sign_in_as users(:admin)

    get new_certificate_type_path

    assert_select "input[name=?][value='24']", "certificate_type[validity_months]"
  end

  test "anonymous users are sent to sign in" do
    get certificate_types_path
    assert_redirected_to new_session_path
  end

  test "viewers and managers can see the list but no write controls" do
    %i[viewer manager].each do |role|
      sign_in_as users(role)

      get certificate_types_path

      assert_response :success, "#{role} index"
      assert_select "title", "Master list · CertTrack"
      assert_select "tr##{dom_id(certificate_types(:osha30))}"
      assert_select "a[href=?]", new_certificate_type_path, count: 0
      assert_select "a[href=?]", edit_certificate_type_path(certificate_types(:osha30)), count: 0
      assert_select "tbody form", count: 0
      sign_out
    end
  end

  test "managers and viewers get 403 on every write action" do
    type = certificate_types(:flagger)

    %i[manager viewer].each do |role|
      sign_in_as users(role)

      get new_certificate_type_path
      assert_response :forbidden, "#{role} new"
      assert_select "h1", "Not allowed"

      assert_no_difference -> { CertificateType.count } do
        post certificate_types_path, params: { certificate_type: { name: "Sneaky", code: "SNEAKY" } }
      end
      assert_response :forbidden, "#{role} create"

      get edit_certificate_type_path(type)
      assert_response :forbidden, "#{role} edit"

      patch certificate_type_path(type), params: { certificate_type: { validity_months: 1, active: false } }
      assert_response :forbidden, "#{role} update"

      assert_no_difference -> { CertificateType.count } do
        delete certificate_type_path(certificate_types(:retired_hazwoper))
      end
      assert_response :forbidden, "#{role} destroy"

      patch move_certificate_type_path(type), params: { direction: "up" }
      assert_response :forbidden, "#{role} move"

      type.reload
      assert_equal [ 36, true, 2 ], [ type.validity_months, type.active, type.position ]
      sign_out
    end
  end

  # --- Index ---

  test "index lists active types by position then name with validity, aliases and usage counts" do
    tied = CertificateType.create!(name: "Asbestos Awareness", code: "ASBESTOS", position: 2, validity_months: 1)
    unpositioned = CertificateType.create!(name: "Aerial Lift", code: "AERIAL")
    sign_in_as users(:viewer)

    get certificate_types_path

    assert_response :success
    expected = [ certificate_types(:osha30), tied, certificate_types(:flagger), certificate_types(:first_aid),
      certificate_types(:climber), certificate_types(:cdl_a), unpositioned ]
    assert_equal expected.map { dom_id(it) }, css_select("tbody tr").map { it["id"] }

    osha30 = certificate_types(:osha30)
    assert_select "tr##{dom_id(osha30)}" do
      assert_select "td[data-column=code]", "OSHA30"
      assert_select "td[data-column=name]", /OSHA 30 Construction/
      assert_select "td[data-column=issuing-body]", "OSHA Outreach Training Program"
      assert_select "td[data-column=validity]", "Never expires"
      assert_select "td[data-column=aliases] li", "OSHA 30-Hour Construction Industry Outreach Training"
      assert_select "td[data-column=status]", "Active"
      assert_select "td[data-column=current-certificates]", osha30.certificates.current.count.to_s
      assert_select "td[data-column=projects]", "2" # tower_2417 and closed_2390
    end

    flagger = certificate_types(:flagger)
    assert_operator flagger.certificates.count, :>, flagger.certificates.current.count, "fixture has flagger history"
    assert_select "tr##{dom_id(flagger)}" do
      assert_select "td[data-column=validity]", "36 months"
      assert_select "td[data-column=current-certificates]", flagger.certificates.current.count.to_s
      assert_select "td[data-column=projects]", "1"
    end
    assert_select "tr##{dom_id(tied)} td[data-column=validity]", "1 month"
    assert_select "tr##{dom_id(unpositioned)} td[data-column=aliases]", "—"
    assert_select "tr##{dom_id(unpositioned)} td[data-column=projects]", "0"
    assert_select "tr##{dom_id(certificate_types(:retired_hazwoper))}", count: 0
  end

  test "index shows only the first two aliases and how many more" do
    type = CertificateType.create!(name: "Rigger", code: "RIGGER", aliases: [ "Rigger Level 1", "Qualified Rigger", "Signal Person" ])
    sign_in_as users(:viewer)

    get certificate_types_path

    assert_select "tr##{dom_id(type)} td[data-column=aliases]" do
      assert_select "li", 3
      assert_select "li", "+1 more"
    end
    assert_equal "Rigger Level 1\nQualified Rigger\nSignal Person", css_select("tr##{dom_id(type)} ul").first["title"]
  end

  test "status filter shows inactive types muted, and all types together" do
    retired = certificate_types(:retired_hazwoper)
    sign_in_as users(:viewer)

    get certificate_types_path(status: "inactive")
    assert_select "tbody tr", 1
    assert_select "tr##{dom_id(retired)}.text-gray-400" do
      assert_select "td[data-column=status]", "Inactive"
    end
    assert_select "nav[aria-label=?] a[aria-current=page]", "Filter by status", /Inactive\s+1/

    get certificate_types_path(status: "all")
    assert_select "tbody tr", CertificateType.count
    assert_select "tr##{dom_id(retired)}"
    assert_select "tr##{dom_id(certificate_types(:osha30))}:not(.text-gray-400)"

    get certificate_types_path(status: "bogus")
    assert_select "tbody tr", CertificateType.active.count
  end

  test "index shows empty states" do
    sign_in_as @admin
    CertificateType.where(active: false).update_all(active: true)

    get certificate_types_path(status: "inactive")
    assert_select "tbody", count: 0
    assert_select "p", "No inactive certificate types"

    ImportItem.update_all(certificate_id: nil, matched_certificate_type_id: nil)
    Certificate.delete_all
    ProjectRequirement.delete_all
    CertificateType.delete_all

    get certificate_types_path
    assert_select "p", "No certificate types yet"
    assert_select "a[href=?]", new_certificate_type_path, minimum: 1
  end

  test "admin sees new, edit, move, deactivate and delete only for unused types" do
    unused = CertificateType.create!(name: "Aerial Lift", code: "AERIAL")
    sign_in_as @admin

    get certificate_types_path(status: "all")

    assert_select "a[href=?]", new_certificate_type_path
    assert_select "tr##{dom_id(certificate_types(:osha30))}" do
      assert_select "a[href=?]", edit_certificate_type_path(certificate_types(:osha30))
      assert_select "form[action=?] button", certificate_type_path(certificate_types(:osha30)), "Deactivate"
      assert_select "form[action=?] input[name='_method'][value=delete]", certificate_type_path(certificate_types(:osha30)), count: 0
      assert_select "button[aria-label=?][disabled]", "Move OSHA 30 Construction up"
      assert_select "button[aria-label=?]:not([disabled])", "Move OSHA 30 Construction down"
    end
    assert_select "tr##{dom_id(unused)}" do
      assert_select "form[action=?] input[name='_method'][value=delete]", certificate_type_path(unused)
      assert_select "button[aria-label=?][disabled]", "Move Aerial Lift down"
    end
    assert_select "tr##{dom_id(certificate_types(:retired_hazwoper))} button", /Reactivate/
  end

  test "index runs a fixed number of queries regardless of type count" do
    create_used_types = ->(prefix) do
      5.times do |i|
        type = CertificateType.create!(name: "#{prefix} type #{i}", code: "#{prefix}#{i}", aliases: [ "Alias #{i}" ])
        Certificate.create!(crew_member: crew_members(:juan_ortiz), certificate_type: type, completed_on: Date.current - 5)
        ProjectRequirement.create!(project: projects(:tower_2417), certificate_type: type)
      end
    end
    create_used_types.call("A")
    sign_in_as @admin

    queries = count_queries { get certificate_types_path(status: "all") }
    create_used_types.call("B")
    assert_equal queries, count_queries { get certificate_types_path(status: "all") }
  end

  # --- New and create ---

  test "new renders the form with field hints" do
    sign_in_as @admin

    get new_certificate_type_path

    assert_response :success
    assert_select "title", "New certificate type · CertTrack"
    assert_select "form[action=?]", certificate_types_path do
      %w[name code issuing_body position validity_months description].each do |field|
        assert_select "[name=?]", "certificate_type[#{field}]"
      end
      assert_select "textarea[name=?]", "certificate_type[aliases]"
      assert_select "input[type=checkbox][name=?][checked]", "certificate_type[active]"
    end
    assert_select "#validity_hint", /Leave blank if this certificate never expires/
    assert_select "#aliases_hint", /One per line/
    assert_select "#validity_note", count: 0
  end

  test "create saves a type with an uppercased code and one alias per line" do
    sign_in_as @admin

    assert_difference -> { CertificateType.count } do
      post certificate_types_path, params: { certificate_type: {
        name: "  Fall   Protection ", code: " fall-prot ", issuing_body: "ANSI", validity_months: "12", position: "6",
        aliases: "Fall Protection Competent Person\r\n\r\n  Fall Arrest, Rescue and Suspension \r\nfall protection competent person\n",
        description: "Harness and lanyard use.", active: "1"
      } }
    end

    type = CertificateType.order(:id).last
    assert_redirected_to certificate_types_path
    assert_equal "Added Fall Protection to the master list.", flash[:notice]
    assert_equal [ "Fall Protection", "FALL-PROT", "ANSI", 12, 6, true ], [ type.name, type.code, type.issuing_body, type.validity_months, type.position, type.active ]
    assert_equal [ "Fall Protection Competent Person", "Fall Arrest, Rescue and Suspension" ], type.aliases

    get edit_certificate_type_path(type)
    assert_select "textarea[name=?]", "certificate_type[aliases]", text: "Fall Protection Competent Person\nFall Arrest, Rescue and Suspension"
  end

  test "create with blank validity means the type never expires" do
    sign_in_as @admin

    post certificate_types_path, params: { certificate_type: { name: "OSHA 10 Construction", code: "osha10", validity_months: "", position: "", aliases: "" } }

    type = CertificateType.find_by_code("OSHA10")
    assert type.never_expires?
    assert_nil type.position
    assert_equal [], type.aliases
  end

  test "create an inactive type returns to a list that shows it" do
    sign_in_as @admin

    post certificate_types_path, params: { certificate_type: { name: "Legacy", code: "LEGACY", active: "0" } }

    assert_redirected_to certificate_types_path(status: "all")
  end

  test "create with errors re-renders the form and keeps the aliases" do
    sign_in_as @admin

    assert_no_difference -> { CertificateType.count } do
      post certificate_types_path, params: { certificate_type: {
        name: "Flagger", code: "bad code!", validity_months: "0", aliases: "One\nTwo"
      } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation" do
      assert_select "li", "Name has already been taken"
      assert_select "li", /Code may only contain letters, digits, - and _/
      assert_select "li", "Validity months must be greater than 0"
    end
    assert_select "textarea[name=?]", "certificate_type[aliases]", text: "One\nTwo"
  end

  # --- Edit and update ---

  test "edit shows aliases one per line, usage and the validity note" do
    type = certificate_types(:flagger)
    sign_in_as @admin

    get edit_certificate_type_path(type)

    assert_response :success
    assert_select "title", "Edit Flagger · CertTrack"
    assert_select "textarea[name=?]", "certificate_type[aliases]", text: "Flagger Certification\nTraffic Control Flagger"
    assert_select "#validity_note", /Changing validity re-dates existing certificates that have no date from the card/
    assert_select "#validity_note", /Of the #{type.certificates.count} certificates of this type/
    assert_select "#validity_note", /printed on a card or typed in by hand are kept/
    assert_select "p", /Used by #{type.certificates.count} certificates, 1 project, and #{type.matched_import_items.count} import items?\./
    assert_select "form[action=?] button", certificate_type_path(type), "Deactivate"
  end

  test "edit offers delete for an unused type" do
    type = CertificateType.create!(name: "Aerial Lift", code: "AERIAL")
    sign_in_as @admin

    get edit_certificate_type_path(type)

    assert_select "p", /Not used by any certificate/
    assert_select "form[action=?] button", certificate_type_path(type), "Delete"
  end

  test "edit of an inactive type in use offers no delete" do
    type = certificate_types(:climber)
    type.update!(active: false)
    sign_in_as @admin

    get edit_certificate_type_path(type)

    assert_select "#danger_zone p", /can't be deleted\. It's already inactive\./
    assert_select "#danger_zone form", count: 0
    assert_select "a[href=?]", certificate_types_path(status: "all"), "← Master list"
  end

  test "update saves changes, round-trips aliases and re-dates computed certificates" do
    type = CertificateType.create!(name: "Rigger", code: "RIGGER", validity_months: 12, aliases: [ "Old alias" ])
    completed_on = Date.current - 30
    certificate = Certificate.create!(crew_member: crew_members(:li_chen), certificate_type: type, completed_on: completed_on)
    manual = Certificate.create!(crew_member: crew_members(:juan_ortiz), certificate_type: type, completed_on: completed_on,
      expires_on: Date.current + 100)
    assert certificate.expiry_computed?
    sign_in_as @admin

    patch certificate_type_path(type), params: { certificate_type: {
      validity_months: "24", aliases: "Rigger and Signal Person\nQualified Rigger", issuing_body: "NCCCO"
    } }

    assert_redirected_to certificate_types_path
    assert_equal "Saved Rigger. Re-dated 1 certificate that had no date from the card.", flash[:notice]
    type.reload
    assert_equal 24, type.validity_months
    assert_equal [ "Rigger and Signal Person", "Qualified Rigger" ], type.aliases
    assert_equal "NCCCO", type.issuing_body
    assert_equal completed_on.advance(months: 24), certificate.reload.expires_on
    assert_equal Date.current + 100, manual.reload.expires_on

    patch certificate_type_path(type), params: { certificate_type: { validity_months: "" } }
    assert type.reload.never_expires?
    assert_nil certificate.reload.expires_on
    assert certificate.expiry_none?
    assert_equal Date.current + 100, manual.reload.expires_on

    patch certificate_type_path(type), params: { certificate_type: { validity_months: "6" } }
    assert_equal completed_on.advance(months: 6), certificate.reload.expires_on

    patch certificate_type_path(type), params: { certificate_type: { issuing_body: "ANSI" } }
    assert_equal "Saved Rigger.", flash[:notice], "no validity change, no re-dating sentence"
  end

  test "update without an aliases field leaves aliases alone" do
    type = certificate_types(:flagger)
    sign_in_as @admin

    patch certificate_type_path(type), params: { certificate_type: { description: "Directs traffic." } }

    assert_equal [ "Flagger Certification", "Traffic Control Flagger" ], type.reload.aliases
  end

  test "update with errors re-renders edit" do
    type = certificate_types(:flagger)
    sign_in_as @admin

    patch certificate_type_path(type), params: { certificate_type: { name: "", code: "OSHA30" } }

    assert_response :unprocessable_entity
    assert_select "title", "Edit Flagger · CertTrack"
    assert_select "#error_explanation li", "Name can't be blank"
    assert_select "#error_explanation li", "Code has already been taken"
    assert_equal "Flagger", type.reload.name
  end

  test "deactivate and reactivate from the list keep the list filter" do
    type = certificate_types(:flagger)
    sign_in_as @admin

    patch certificate_type_path(type), params: { certificate_type: { active: false }, status: "" }
    assert_redirected_to certificate_types_path
    assert_match "Deactivated Flagger.", flash[:notice]
    assert_not type.reload.active?

    patch certificate_type_path(type), params: { certificate_type: { active: true }, status: "inactive" }
    assert_redirected_to certificate_types_path(status: "inactive")
    assert_equal "Reactivated Flagger.", flash[:notice]
    assert type.reload.active?
  end

  # --- Destroy ---

  test "destroy deletes an unused type" do
    type = CertificateType.create!(name: "Aerial Lift", code: "AERIAL")
    sign_in_as @admin

    assert_difference -> { CertificateType.count }, -1 do
      delete certificate_type_path(type)
    end

    assert_redirected_to certificate_types_path
    assert_equal "Deleted Aerial Lift.", flash[:notice]
  end

  test "destroy deletes an unused inactive type" do
    sign_in_as @admin

    assert_difference -> { CertificateType.count }, -1 do
      delete certificate_type_path(certificate_types(:retired_hazwoper)), params: { status: "inactive" }
    end

    assert_redirected_to certificate_types_path(status: "inactive")
  end

  test "destroy deactivates a type in use and explains why" do
    type = certificate_types(:climber)
    sign_in_as @admin

    assert_no_difference -> { CertificateType.count } do
      delete certificate_type_path(type)
    end

    assert_redirected_to certificate_types_path(status: "all")
    assert_not type.reload.active?
    assert_match(/\AAuthorized Climber is used by 1 certificate and 1 project, so it can't be deleted\. It was deactivated instead/, flash[:notice])
    assert_equal 1, type.certificates.count
    assert_equal 1, type.project_requirements.count
  end

  test "destroy of a type used only by a project requirement deactivates it" do
    type = CertificateType.create!(name: "Aerial Lift", code: "AERIAL")
    ProjectRequirement.create!(project: projects(:closed_2390), certificate_type: type)
    sign_in_as @admin

    delete certificate_type_path(type), params: { status: "" }

    assert_redirected_to certificate_types_path
    assert_not type.reload.active?
    assert_match "used by 1 project,", flash[:notice]
  end

  test "destroy of a type matched only by an import item deactivates it and keeps the match" do
    type = CertificateType.create!(name: "Aerial Lift", code: "AERIAL")
    item = ImportItem.create!(import_batch: import_batches(:march_batch), original_filename: "lift.jpg",
      sha256: "b" * 64, matched_certificate_type: type)
    sign_in_as @admin

    assert_no_difference -> { CertificateType.count } do
      delete certificate_type_path(type)
    end

    assert_not type.reload.active?
    assert_match "used by 1 import item,", flash[:notice]
    assert_equal type, item.reload.matched_certificate_type
  end

  test "destroy of an inactive type in use leaves it and says so" do
    type = certificate_types(:climber)
    type.update!(active: false)
    sign_in_as @admin

    delete certificate_type_path(type)

    assert_redirected_to certificate_types_path(status: "all")
    assert_match "It's already inactive.", flash[:alert]
    assert CertificateType.exists?(type.id)
  end

  # --- Move ---

  test "move up and down swaps neighbours and renumbers every type" do
    unpositioned = CertificateType.create!(name: "Aerial Lift", code: "AERIAL")
    sign_in_as @admin

    patch move_certificate_type_path(certificate_types(:first_aid)), params: { direction: "up", status: "" }

    assert_redirected_to certificate_types_path
    assert_equal %w[OSHA30 FIRSTAID FLAGGER CLIMBER CDLA HAZWOPER40 AERIAL], CertificateType.ordered.pluck(:code)
    assert_equal (1..7).to_a, CertificateType.ordered.pluck(:position)

    patch move_certificate_type_path(unpositioned), params: { direction: "up", status: "all" }
    assert_redirected_to certificate_types_path(status: "all")
    assert_equal %w[OSHA30 FIRSTAID FLAGGER CLIMBER CDLA AERIAL HAZWOPER40], CertificateType.ordered.pluck(:code)

    patch move_certificate_type_path(certificate_types(:osha30)), params: { direction: "down" }
    assert_equal %w[FIRSTAID OSHA30 FLAGGER], CertificateType.ordered.limit(3).pluck(:code)
  end

  test "move skips types hidden by the list filter" do
    certificate_types(:retired_hazwoper).update!(position: 4) # sorts between climber (4, by name) and cdl_a (5)
    sign_in_as @admin

    patch move_certificate_type_path(certificate_types(:cdl_a)), params: { direction: "up", status: "" }

    assert_equal %w[OSHA30 FLAGGER FIRSTAID CDLA HAZWOPER40 CLIMBER], CertificateType.ordered.pluck(:code)
  end

  test "move past either end, or with a bad direction, changes nothing" do
    sign_in_as @admin

    assert_no_changes -> { CertificateType.ordered.pluck(:id, :position) } do
      patch move_certificate_type_path(certificate_types(:osha30)), params: { direction: "up" }
      patch move_certificate_type_path(certificate_types(:cdl_a)), params: { direction: "down" }
      patch move_certificate_type_path(certificate_types(:flagger)), params: { direction: "sideways" }
      patch move_certificate_type_path(certificate_types(:retired_hazwoper)), params: { direction: "up" } # hidden from the active list
    end
    assert_redirected_to certificate_types_path
  end

  private
    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
