require "test_helper"

class CrewMembersControllerTest < ActionDispatch::IntegrationTest
  setup { @juan = crew_members(:juan_ortiz) }

  # --- Access ---

  test "anonymous users are sent to sign in" do
    get crew_members_path
    assert_redirected_to new_session_path
  end

  test "viewers get 403 on every write action and nothing changes" do
    sign_in_as users(:viewer)

    get new_crew_member_path
    assert_response :forbidden

    assert_no_difference -> { CrewMember.count } do
      post crew_members_path, params: { crew_member: { first_name: "Sneaky", last_name: "Viewer" } }
    end
    assert_response :forbidden

    get edit_crew_member_path(@juan)
    assert_response :forbidden

    patch crew_member_path(@juan), params: { crew_member: { last_name: "Changed", active: "0" } }
    assert_response :forbidden
    assert_equal "Ortiz", @juan.reload.last_name
    assert @juan.active?

    unused = CrewMember.create!(first_name: "No", last_name: "History")
    assert_no_difference -> { CrewMember.count } do
      delete crew_member_path(unused)
    end
    assert_response :forbidden
    assert unused.reload.active?
  end

  test "viewers can read the list and a member page but see no edit buttons" do
    sign_in_as users(:viewer)

    get crew_members_path
    assert_response :success
    assert_select "a", text: "Add crew member", count: 0

    get crew_member_path(@juan)
    assert_response :success
    assert_select "a", text: "Add certificate", count: 0
    assert_select "a", text: "Edit", count: 0
    assert_select "button", text: "Deactivate", count: 0
  end

  # --- Index ---

  test "index lists active members by name with role, employer, cert count, worst status and contact" do
    sign_in_as users(:manager)

    get crew_members_path

    assert_response :success
    assert_select "title", "Crew · CertTrack"
    assert_select "#crew_members_count", text: /4 crew members/
    names = css_select("#crew_members_results tbody tr td:first-child a").map { |a| a.text.strip }
    assert_equal [ "Chen, Li", "Garcia, Maria", "Miller, David", "Ortiz, Juan" ], names

    assert_select "tr##{dom_id(@juan)}" do
      assert_select "td", text: "Climber"
      assert_select "td", text: "ABA Ventures"
      assert_select "td", text: "4" # osha30, flagger, first_aid, climber (history excluded)
      assert_select "[data-status=?]", "expiring"
      assert_select "a[href=?]", "mailto:juan.ortiz@example.com"
      assert_select "a[href=?]", "tel:3035550101", text: "303-555-0101"
    end
    assert_select "tr##{dom_id(crew_members(:maria_garcia))} [data-status=?]", "expired"
    assert_select "tr##{dom_id(crew_members(:dave_miller))} [data-status=?]", "missing"
    assert_select "tr##{dom_id(crew_members(:sam_inactive))}", count: 0
    assert_select "a", text: "Add crew member"
  end

  test "index can show inactive members, or everyone" do
    sign_in_as users(:manager)
    sam = crew_members(:sam_inactive)

    get crew_members_path(active: "inactive")
    assert_equal [ sam.id ], listed_member_ids
    # Inactive members are not on any report, so their status is a dash.
    assert_select "tr##{dom_id(sam)}" do
      assert_select "span[title=?]", "Not on an active project", text: "—"
      assert_select "span", text: "Inactive"
    end

    get crew_members_path(active: "all")
    assert_equal 5, listed_member_ids.size
    assert_includes listed_member_ids, sam.id
  end

  test "misspelled search finds the right member first" do
    sign_in_as users(:viewer)

    get crew_members_path(q: "Jaun Ortis")

    assert_response :success
    assert_equal @juan.id, listed_member_ids.first
    assert_not_includes listed_member_ids, crew_members(:li_chen).id
  end

  test "search matches aliases and preferred names" do
    sign_in_as users(:viewer)

    get crew_members_path(q: "Jon Ortiz")
    assert_equal @juan.id, listed_member_ids.first

    get crew_members_path(q: "dave miller")
    assert_equal crew_members(:dave_miller).id, listed_member_ids.first
  end

  test "search inside the results frame returns the frame" do
    sign_in_as users(:viewer)

    get crew_members_path(q: "Jaun Ortis"), headers: { "Turbo-Frame" => "crew_members_results" }

    assert_response :success
    assert_select "turbo-frame#crew_members_results[target=_top]" do
      assert_select "tr##{dom_id(@juan)}"
    end
  end

  test "filters by employer" do
    sign_in_as users(:viewer)

    get crew_members_path(employer: "Skyline Tower Services")

    assert_equal [ crew_members(:li_chen).id ], listed_member_ids
    assert_select "select#employer option[selected]", text: "Skyline Tower Services"
  end

  test "filters by role, including members with no role" do
    sign_in_as users(:viewer)
    roleless = CrewMember.create!(first_name: "Rolf", last_name: "Lessing")

    get crew_members_path(crew_role_id: crew_roles(:operator).id)
    assert_equal [ crew_members(:li_chen).id, crew_members(:dave_miller).id ].sort, listed_member_ids.sort

    get crew_members_path(crew_role_id: "none")
    assert_equal [ roleless.id ], listed_member_ids
  end

  test "filters by compliance status across active projects" do
    sign_in_as users(:viewer)
    maria, li, dave = crew_members(:maria_garcia), crew_members(:li_chen), crew_members(:dave_miller)

    get crew_members_path(status: "expired")
    assert_equal [ maria.id, li.id ].sort, listed_member_ids.sort

    get crew_members_path(status: "missing")
    assert_equal [ maria.id, li.id, dave.id ].sort, listed_member_ids.sort

    get crew_members_path(status: "expiring")
    assert_equal [ @juan.id, dave.id ].sort, listed_member_ids.sort

    get crew_members_path(status: "lapses_on_project")
    assert_equal [ @juan.id ], listed_member_ids

    get crew_members_path(status: "fake")
    assert_empty listed_member_ids
    # Flagged by an automatic check only: still counted by its dates, so not "fake".
    certificates(:juan_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:mismatch],
      authenticity_method: "automatic:aha_ecards")
    get crew_members_path(status: "fake")
    assert_empty listed_member_ids
    certificates(:juan_flagger).update_columns(authenticity_method: Authenticity::PERSON_METHOD)
    get crew_members_path(status: "fake")
    assert_equal [ @juan.id ], listed_member_ids
    assert_select "select[name=status] option[value=fake][selected]", "Has confirmed fake"

    get crew_members_path(status: "flagged") # no longer a filter: ignored
    assert_select "select[name=status] option[selected]", count: 0
  end

  test "filters combine with search" do
    sign_in_as users(:viewer)

    get crew_members_path(q: "Ortiz", status: "expired")

    assert_empty listed_member_ids
    assert_select "p", text: "No crew members match"
    assert_select "a", text: "Clear filters"
  end

  test "unknown filter values are ignored" do
    sign_in_as users(:viewer)

    get crew_members_path(status: "bogus", active: "nonsense", crew_role_id: "abc")

    assert_equal 4, listed_member_ids.size
  end

  test "empty roster shows an empty state" do
    sign_in_as users(:manager)
    CrewMember.update_all(active: false)

    get crew_members_path

    assert_select "p", text: "No crew members yet"
    assert_select "a", text: "Add the first crew member"
  end

  test "index shows only the first 100 and says so" do
    sign_in_as users(:viewer)
    now = Time.current
    CrewMember.insert_all!(Array.new(100) { |i| { first_name: "Bulk#{i}", last_name: "Member", created_at: now, updated_at: now } })

    get crew_members_path

    assert_equal 100, listed_member_ids.size
    assert_select "#crew_members_count", text: /Showing first 100 of 104 crew members/
  end

  test "index runs a bounded number of queries however many members there are" do
    sign_in_as users(:manager)
    get crew_members_path # warm up schema and session lookups

    baseline = count_queries { get crew_members_path(active: "all") }

    project = projects(:tower_2417)
    6.times do |i|
      member = CrewMember.create!(first_name: "Extra#{i}", last_name: "Person", employer: "Employer #{i}",
        email: "extra#{i}@example.com", crew_role: crew_roles(:operator))
      project.project_assignments.create!(crew_member: member)
      Certificate.create!(crew_member: member, certificate_type: certificate_types(:osha30), completed_on: Date.current - 30)
      Certificate.create!(crew_member: member, certificate_type: certificate_types(:flagger), completed_on: Date.current - 30)
    end

    assert_equal baseline, count_queries { get crew_members_path(active: "all") }
    assert_equal 11, listed_member_ids.size
  end

  # --- Show ---

  test "show lists current certificates and hides superseded ones until history is on" do
    sign_in_as users(:viewer)

    get crew_member_path(@juan)

    assert_response :success
    assert_select "title", "Juan Ortiz · CertTrack"
    assert_select "#current_certificates tbody tr", 4
    assert_select "#current_certificates", text: /FL-20002/
    assert_select "#current_certificates tr##{dom_id(certificates(:juan_flagger))} [data-status=?]", "expiring"
    assert_select "#current_certificates tr##{dom_id(certificates(:juan_osha30))}", text: /Never/
    assert_select "#current_certificates a[href=?]", crew_member_certificate_path(@juan, certificates(:juan_flagger))
    assert_select "#superseded_certificates", count: 0
    assert_no_match "FL-10001", response.body
    assert_select "a[href=?]", crew_member_path(@juan, history: 1, anchor: "history"), text: "Show history (2 older)"

    get crew_member_path(@juan, history: 1)

    assert_select "#superseded_certificates tbody tr", 2
    assert_select "#superseded_certificates tr##{dom_id(certificates(:juan_flagger_old))}", text: /FL-10001/
    assert_select "#current_certificates tbody tr", 4
    assert_select "a", text: "Hide history"
  end

  test "history marks a confirmed fake certificate kept behind a genuine one" do
    certificates(:juan_flagger).record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    sign_in_as users(:viewer)

    get crew_member_path(@juan, history: 1)

    assert_select "#current_certificates tr##{dom_id(certificates(:juan_flagger_old))} [data-status=expired]"
    assert_select "#superseded_certificates tr##{dom_id(certificates(:juan_flagger))} [data-status=fake][title=?]",
      "Confirmed fake: Not found by issuer", text: "Confirmed fake"
    assert_select "#superseded_certificates tr##{dom_id(certificates(:juan_first_aid_old))} [data-status]", count: 0
    assert_select "#history", /confirmed fake ones a genuine one on file replaced/
  end

  test "show lists details, aliases and expiry email opt-in" do
    sign_in_as users(:viewer)

    get crew_member_path(crew_members(:maria_garcia))

    assert_select "h1", text: /Mari Garcia/
    assert_select "dd", text: "Maria Garcia"
    assert_select "#name_aliases", text: "María García-López"
    assert_select "#expiry_emails", text: "No"
  end

  test "show warns when a member opted in to expiry emails without an email" do
    sign_in_as users(:viewer)
    dave = crew_members(:dave_miller)
    dave.update!(expiry_emails_opt_in: true)

    get crew_member_path(dave)

    assert_select "#expiry_emails", text: /No email on file/
  end

  test "show lists each project assignment with this person's required types and statuses" do
    sign_in_as users(:viewer)

    get crew_member_path(@juan)

    tower = project_assignments(:tower_juan)
    assert_select "##{dom_id(tower)}" do
      assert_select "a[href=?]", project_path(projects(:tower_2417)), text: "2417 · Tower 2417 Upgrade"
      assert_select "li[data-status]", 4 # osha30, flagger, first_aid, climber (no CDL for climbers)
      assert_select "li[data-status=valid]", 2
      assert_select "li[data-status=expiring]", text: /Flagger/
      assert_select "li[data-status=lapses_on_project]", text: /First Aid/
      assert_select "a[href=?]", crew_member_certificate_path(@juan, certificates(:juan_flagger))
    end
    assert_select "##{dom_id(project_assignments(:closed_juan))}", text: /Project closed/
  end

  test "show marks a certificate a person confirmed fake on the certificate list and the project requirements" do
    sign_in_as users(:viewer)
    certificates(:juan_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:not_found],
      authenticity_method: Authenticity::PERSON_METHOD)

    get crew_member_path(@juan)

    assert_select "#current_certificates tr##{dom_id(certificates(:juan_flagger))} span[data-status=fake]",
      text: "Confirmed fake" do |spans|
      assert_equal "Confirmed fake: Not found by issuer", spans.first["title"]
      assert_includes spans.first["class"], "bg-red-800"
    end
    assert_select "#current_certificates [data-authenticity-review]", count: 0
    assert_select "#current_certificates tr##{dom_id(certificates(:juan_osha30))} [data-status=valid]"
    assert_select "##{dom_id(project_assignments(:tower_juan))} li[data-status=fake]", text: /Flagger.*Confirmed fake/m
  end

  test "show keeps a certificate an automatic check flagged at its date status, with a Review marker" do
    sign_in_as users(:viewer)
    certificates(:juan_flagger).update_columns(authenticity_status: Certificate.authenticity_statuses[:not_found],
      authenticity_method: "automatic:aha_ecards")

    get crew_member_path(@juan)

    assert_select "#current_certificates tr##{dom_id(certificates(:juan_flagger))}" do
      assert_select "span[data-status=expiring]"
      assert_select "span[data-authenticity-review=not_found][title^=?]", "Flagged for review: Not found by issuer.", text: /Review/
    end
    assert_select "#current_certificates [data-authenticity-review]", 1
    assert_select "##{dom_id(project_assignments(:tower_juan))} li[data-status=expiring]", text: /Flagger/ do
      assert_select "[data-authenticity-review=not_found]"
    end
    assert_select "[data-status=fake]", count: 0
  end

  test "index shows confirmed fake as a member's worst status, but not a flag for review" do
    sign_in_as users(:manager)
    certificates(:juan_osha30).update_columns(authenticity_status: Certificate.authenticity_statuses[:suspicious],
      authenticity_method: "qr_link")

    get crew_members_path
    assert_select "tr##{dom_id(@juan)} [data-status=?]", "expiring" # juan_flagger, as without the flag

    certificates(:juan_osha30).update_columns(authenticity_status: Certificate.authenticity_statuses[:mismatch],
      authenticity_method: Authenticity::PERSON_METHOD)
    get crew_members_path
    assert_select "tr##{dom_id(@juan)} [data-status=?]", "fake", text: "Confirmed fake"
  end

  test "show says an ended assignment on an active project is no longer tracked" do
    sign_in_as users(:viewer)
    tower = project_assignments(:tower_juan)
    tower.update!(ends_on: Date.current - 1)

    get crew_member_path(@juan)

    assert_select "##{dom_id(tower)}" do
      assert_select "p", text: /Assignment ended/
      assert_select "li[data-status]", 0
    end
  end

  test "show uses the project role override and marks missing types" do
    sign_in_as users(:viewer)
    li = crew_members(:li_chen)

    get crew_member_path(li)

    assert_select "##{dom_id(project_assignments(:tower_li_chen))}" do
      assert_select "p", text: /Climber \(project override\)/
      assert_select "li[data-status=missing]", text: /Climber/
      assert_select "li[data-status=expired]", text: /First Aid/
    end
  end

  test "show runs a bounded number of queries however many projects and certificates there are" do
    sign_in_as users(:viewer)
    get crew_member_path(@juan, history: 1) # warm up

    baseline = count_queries { get crew_member_path(@juan, history: 1) }

    3.times do |i|
      type = CertificateType.create!(name: "Extra type #{i}", code: "EXTRA#{i}", validity_months: 12)
      project = Project.create!(name: "Extra project #{i}", code: "X#{i}", status: :active, ends_on: Date.current + 90)
      project.project_requirements.create!(certificate_type: type)
      project.project_requirements.create!(certificate_type: certificate_types(:flagger))
      project.project_assignments.create!(crew_member: @juan)
      Certificate.create!(crew_member: @juan, certificate_type: type, completed_on: Date.current - 400) # superseded below
      Certificate.create!(crew_member: @juan, certificate_type: type, completed_on: Date.current - 20)
    end

    assert_equal baseline, count_queries { get crew_member_path(@juan, history: 1) }
    assert_select "#current_certificates tbody tr", 7
    assert_select "#superseded_certificates tbody tr", 5
  end

  test "show lists active projects before planned and closed ones" do
    sign_in_as users(:viewer)
    planned = Project.create!(name: "Alpha planned", status: :planned)
    planned.project_assignments.create!(crew_member: @juan)

    get crew_member_path(@juan)

    order = css_select("#assignments > ul > li").map { |li| li["id"] }
    assert_equal [ project_assignments(:tower_juan), planned.project_assignments.first, project_assignments(:closed_juan) ].map { |a| dom_id(a) }, order
  end

  test "show for an inactive member offers reactivation and skips compliance" do
    sign_in_as users(:manager)
    sam = crew_members(:sam_inactive)

    get crew_member_path(sam)

    assert_select "h1 span", text: "Inactive"
    assert_select "button", text: "Reactivate"
    assert_select "button", text: "Deactivate", count: 0
    assert_select "p", text: /Inactive members aren't checked/
    assert_select "li[data-status]", count: 0
  end

  test "editors see the add certificate, edit and deactivate buttons, and delete only without history" do
    sign_in_as users(:manager)

    get crew_member_path(@juan)
    assert_select "a[href=?]", new_crew_member_certificate_path(@juan), text: "Add certificate"
    assert_select "a[href=?]", edit_crew_member_path(@juan), text: "Edit"
    assert_select "button", text: "Deactivate"
    assert_select "button", text: "Delete", count: 0

    fresh = CrewMember.create!(first_name: "Fresh", last_name: "Hire")
    get crew_member_path(fresh)
    assert_select "button", text: "Delete"
    assert_select "p", text: "No certificates on file"
    assert_select "p", text: "Not assigned to any project"
  end

  # --- New / create ---

  test "new renders the form" do
    sign_in_as users(:manager)

    get new_crew_member_path

    assert_response :success
    assert_select "title", "Add crew member · CertTrack"
    assert_select "datalist#employer_options option[value=?]", "Skyline Tower Services"
    assert_select "select#crew_member_crew_role_id option", text: "Climber"
    assert_select "label", text: "Email this person 30 and 7 days before a certificate expires (needs an email)"
  end

  test "create saves a member with aliases from the textarea" do
    sign_in_as users(:admin)

    assert_difference -> { CrewMember.count }, 1 do
      post crew_members_path, params: { crew_member: {
        first_name: " Robert ", last_name: "Smith", preferred_name: "Bob", name_aliases: "Bob Smith\r\n  J. R. Smith \r\n\r\nbob smith",
        email: "Bob.Smith@Example.com", phone: "720-555-0199", employer: "Skyline Tower Services",
        crew_role_id: crew_roles(:climber).id, active: "1", expiry_emails_opt_in: "1", notes: "Started in May."
      } }
    end

    member = CrewMember.order(:id).last
    assert_redirected_to crew_member_path(member)
    assert_equal "Added Bob Smith.", flash[:notice]
    assert_equal "Robert", member.first_name
    assert_equal [ "Bob Smith", "J. R. Smith" ], member.name_aliases
    assert_equal "bob.smith@example.com", member.email
    assert_equal crew_roles(:climber), member.crew_role
    assert member.expiry_emails_opt_in?
    assert_equal "Started in May.", member.notes
  end

  test "create shows validation errors" do
    sign_in_as users(:manager)

    assert_no_difference -> { CrewMember.count } do
      post crew_members_path, params: { crew_member: { first_name: "Only", last_name: "", email: "not-an-email" } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "Last name can't be blank"
    assert_select "#error_explanation li", text: "Email is invalid"
  end

  # --- Edit / update ---

  test "edit prefills aliases one per line" do
    sign_in_as users(:manager)

    get edit_crew_member_path(@juan)

    assert_response :success
    assert_select "title", "Edit Juan Ortiz · CertTrack"
    assert_select "textarea#crew_member_name_aliases", text: "Jon Ortiz\nJuan Ortiz-Ruiz"
  end

  test "update saves changes" do
    sign_in_as users(:manager)

    patch crew_member_path(@juan), params: { crew_member: {
      preferred_name: "Johnny", name_aliases: "Jon Ortiz", employer: "Skyline Tower Services",
      crew_role_id: crew_roles(:foreman).id, expiry_emails_opt_in: "0"
    } }

    assert_redirected_to crew_member_path(@juan)
    assert_equal "Saved Johnny Ortiz.", flash[:notice]
    @juan.reload
    assert_equal "Johnny", @juan.preferred_name
    assert_equal [ "Jon Ortiz" ], @juan.name_aliases
    assert_equal crew_roles(:foreman), @juan.crew_role
    assert_not @juan.expiry_emails_opt_in?
  end

  test "update can clear every alias and the role" do
    sign_in_as users(:manager)

    patch crew_member_path(@juan), params: { crew_member: { name_aliases: "", crew_role_id: "" } }

    @juan.reload
    assert_equal [], @juan.name_aliases
    assert_nil @juan.crew_role
  end

  test "update shows validation errors" do
    sign_in_as users(:manager)

    patch crew_member_path(@juan), params: { crew_member: { first_name: "", email: "nope" } }

    assert_response :unprocessable_entity
    assert_select "#error_explanation li", text: "First name can't be blank"
    assert_equal "Juan", @juan.reload.first_name
  end

  test "deactivate and reactivate go through update" do
    sign_in_as users(:manager)

    patch crew_member_path(@juan), params: { crew_member: { active: "0" } }
    assert_redirected_to crew_member_path(@juan)
    assert_equal "Deactivated Juan Ortiz. Their history is kept.", flash[:notice]
    assert_not @juan.reload.active?

    patch crew_member_path(@juan), params: { crew_member: { active: "1" } }
    assert_equal "Reactivated Juan Ortiz.", flash[:notice]
    assert @juan.reload.active?
  end

  # --- Destroy ---

  test "destroy deletes a member with no certificates or assignments" do
    sign_in_as users(:manager)
    fresh = CrewMember.create!(first_name: "Fresh", last_name: "Hire")

    assert_difference -> { CrewMember.count }, -1 do
      delete crew_member_path(fresh)
    end

    assert_redirected_to crew_members_path
    assert_equal "Deleted Fresh Hire.", flash[:notice]
  end

  test "destroy deactivates a member with history instead of deleting" do
    sign_in_as users(:manager)

    assert_no_difference -> { CrewMember.count }, -> { Certificate.count } do
      delete crew_member_path(@juan)
    end

    assert_redirected_to crew_member_path(@juan)
    assert_match "deactivated instead of deleted", flash[:notice]
    assert_not @juan.reload.active?
  end

  test "destroy deactivates a member who only has assignments" do
    sign_in_as users(:manager)
    member = CrewMember.create!(first_name: "Assigned", last_name: "Only")
    projects(:tower_2417).project_assignments.create!(crew_member: member)

    assert_no_difference -> { CrewMember.count } do
      delete crew_member_path(member)
    end

    assert_not member.reload.active?
  end

  private
    def listed_member_ids
      css_select("#crew_members_results tbody tr[id]").map { |row| row["id"].delete_prefix("crew_member_").to_i }
    end

    # SQL statements the block issues (query-cache hits included), ignoring schema lookups
    # and transactions. The query cache outlives requests in tests, so it is cleared first.
    def count_queries(&block)
      ActiveRecord::Base.connection_pool.clear_query_cache
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
