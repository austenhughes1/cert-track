require "test_helper"

class ComplianceControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:tower_2417)
  end

  test "requires sign-in" do
    get project_compliance_path(@project)
    assert_redirected_to new_session_path
  end

  test "viewer sees every status, with cells linking to certificates" do
    sign_in_as users(:viewer)
    confirm_fake certificates(:li_flagger) # the fixtures hold no confirmed fake certificate

    get project_compliance_path(@project)

    assert_response :success
    assert_select "title", /Compliance · 2417 · Tower 2417 Upgrade/
    (Compliance::STATUSES + [ "not_required" ]).each do |status|
      assert_select "#compliance_matrix td[data-status=?]", status, minimum: 1
    end
    assert_select "#compliance_matrix thead th[title=?]", certificate_types(:osha30).name, text: /OSHA30/
    assert_select "#compliance_matrix tbody tr", 4

    juan = crew_members(:juan_ortiz)
    assert_select "##{dom_id(juan, :compliance_row)} th a[href=?]", crew_member_path(juan), text: "Ortiz, Juan"
    assert_select "##{dom_id(juan, :compliance_row)} td[data-type=FLAGGER][data-status=expiring] a[href=?]",
      crew_member_certificate_path(juan, certificates(:juan_flagger))

    # Viewers can't add certificates, so missing cells are plain badges.
    assert_select "a[href^=?]", new_crew_member_certificate_path(crew_members(:maria_garcia)), count: 0
    assert_select "a", text: "Edit requirements", count: 0
  end

  test "a certificate a person confirmed fake shows as a red Confirmed fake cell and a gap" do
    sign_in_as users(:manager)
    li = crew_members(:li_chen)
    confirm_fake certificates(:li_flagger), :mismatch

    get project_compliance_path(@project)

    assert_select "##{dom_id(li, :compliance_row)} td[data-type=FLAGGER][data-status=fake]" do
      assert_select "a[href=?]", crew_member_certificate_path(li, certificates(:li_flagger)) do
        assert_select "span.bg-red-800[title=?]", "Confirmed fake: Doesn't match issuer", text: "Confirmed fake"
      end
      assert_select "[data-authenticity-review]", count: 0
    end
    assert_select "##{dom_id(li, :compliance_row)} th", text: /3 gaps/
    assert_select "[data-summary-status=fake] dd", text: "1"
    assert_select "[data-summary-status=fake] dt", text: "Confirmed fake"
    assert_select "[data-gap-count=?]", "6", text: /6 gaps/
    assert_select "#compliance_gaps tbody tr", 6
    assert_select "#compliance_gaps tbody tr", text: /FLAGGER.*Confirmed fake.*View certificate.*Add replacement/m
    assert_select "#compliance_gaps h2", text: /\(missing, expired or confirmed fake\)/
    assert_select "#compliance_summary p", text: /Confirmed fake means a person checked it with the issuer/
    assert_select "#compliance_summary p", text: /Review mark means an automatic check or QR code found a problem; the certificate still counts by its dates/
  end

  test "a certificate an automatic check flagged still counts by its dates, with a Review marker" do
    sign_in_as users(:manager)
    li = crew_members(:li_chen)
    gaps_before = Compliance::ProjectReport.new(@project).gaps.size
    flag_for_review certificates(:li_flagger), :not_found

    get project_compliance_path(@project)

    assert_select "##{dom_id(li, :compliance_row)} td[data-type=FLAGGER][data-status=valid]" do
      assert_select "a[href=?]", crew_member_certificate_path(li, certificates(:li_flagger)) do
        assert_select "span[data-status=valid]"
        assert_select "span[data-authenticity-review=not_found][title=?]",
          "Flagged for review: Not found by issuer. It still counts until someone checks it with the issuer.", text: /Review/
      end
    end
    assert_select "#compliance_matrix [data-authenticity-review]", 1
    assert_select "[data-summary-status=fake] dd", text: "0"
    assert_select "[data-gap-count=?]", gaps_before.to_s
    assert_select "#compliance_gaps tbody tr", text: /Chen, Li.*FLAGGER/m, count: 0
  end

  test "flagged for review: automatic not_found, mismatch and suspicious, and a suspicious one a person somehow set" do
    sign_in_as users(:viewer)
    li = crew_members(:li_chen)
    summary_before = Compliance::ProjectReport.new(@project).summary

    [ [ :not_found, "automatic:aha_ecards" ], [ :mismatch, "automatic:qr_details360training" ], [ :suspicious, "qr_link" ],
      [ :suspicious, Authenticity::PERSON_METHOD ], [ :mismatch, nil ] ].each do |status, method|
      flag_for_review certificates(:li_flagger), status, method: method

      get project_compliance_path(@project)

      assert_select "##{dom_id(li, :compliance_row)} td[data-type=FLAGGER][data-status=valid] [data-authenticity-review=?]",
        status.to_s, { count: 1 }, "#{status} by #{method.inspect}"
      Compliance::STATUSES.each do |key|
        assert_select "[data-summary-status=?] dd", key, text: summary_before[key].to_s
      end
    end
  end

  test "an expired certificate flagged for review is an expired gap with a Review marker" do
    sign_in_as users(:manager)
    li = crew_members(:li_chen)
    flag_for_review certificates(:li_first_aid), :suspicious, method: "qr_link"

    get project_compliance_path(@project)

    assert_select "##{dom_id(li, :compliance_row)} td[data-type=FIRSTAID][data-status=expired] [data-authenticity-review=suspicious]"
    assert_select "#compliance_gaps tbody tr", text: /Chen, Li.*FIRSTAID/m do
      assert_select "[data-status=expired]"
      assert_select "[data-authenticity-review=suspicious]"
      assert_select "a", text: "Add renewal"
    end
  end

  test "the CSV says confirmed fake only for a person's result" do
    sign_in_as users(:viewer)
    confirm_fake certificates(:li_flagger)

    get project_compliance_path(@project, format: :csv)

    assert_match(/\AChen,Li,Climber,.*,valid,confirmed fake \(#{certificates(:li_flagger).expires_on.iso8601}\),expired /,
      response.body.lines.find { |line| line.start_with?("Chen,") })

    flag_for_review certificates(:li_flagger)
    get project_compliance_path(@project, format: :csv)
    assert_match(/\AChen,Li,Climber,.*,valid,valid \(#{certificates(:li_flagger).expires_on.iso8601}\),expired /,
      response.body.lines.find { |line| line.start_with?("Chen,") })
  end

  test "editors get an add link on missing cells" do
    sign_in_as users(:manager)
    maria = crew_members(:maria_garcia)

    get project_compliance_path(@project)

    assert_select "##{dom_id(maria, :compliance_row)} td[data-type=FLAGGER][data-status=missing] a[href=?]",
      new_crew_member_certificate_path(maria, certificate_type_id: certificate_types(:flagger).id)
    assert_select "a[href=?]", edit_project_requirements_path(@project)
  end

  test "shows the summary counts, gap count and gap list" do
    sign_in_as users(:viewer)
    report = Compliance::ProjectReport.new(@project)

    get project_compliance_path(@project)

    Compliance::STATUSES.each do |status|
      assert_select "[data-summary-status=?] dd", status, text: report.summary[status].to_s
    end
    assert_select "[data-gap-count=?]", report.gaps.size.to_s, text: /#{report.gaps.size} gaps/
    assert_select "#compliance_gaps tbody tr", report.gaps.size
    assert_select "a[href=?]", project_compliance_path(@project, format: :csv), text: "Export CSV"
    assert_select "a[href=?]", project_packet_path(@project)
  end

  test "viewer can export the CSV" do
    sign_in_as users(:viewer)

    get project_compliance_path(@project, format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match %r{attachment; filename="2417-compliance-#{Date.current.iso8601}\.csv"}, response.headers["Content-Disposition"]
    assert_equal Compliance::ProjectReport.new(@project).to_csv, response.body

    lines = response.body.lines
    assert_equal "Last name,First name,Role,Employer,OSHA30,FLAGGER,FIRSTAID,CLIMBER,CDLA", lines.first.chomp
    assert_equal 5, lines.size
    assert_match(/\AGarcia,Maria,Foreman,.*,missing,expired \(#{certificates(:maria_first_aid).expires_on.iso8601}\),not required,not required\n\z/,
      lines.find { |line| line.start_with?("Garcia,") })
  end

  test "CSV file name falls back to the project id" do
    sign_in_as users(:viewer)
    project = Project.create!(name: "No code yet")

    get project_compliance_path(project, format: :csv)

    assert_match %r{filename="#{project.id}-compliance-}, response.headers["Content-Disposition"]
  end

  test "empty state when the project has no requirements" do
    sign_in_as users(:manager)
    project = Project.create!(name: "Fresh project", code: "9001")

    get project_compliance_path(project)

    assert_response :success
    assert_select "p", text: "No required certificates yet"
    assert_select "#compliance_matrix", count: 0
  end

  test "empty state when no active crew are assigned" do
    sign_in_as users(:viewer)
    project = Project.create!(name: "Unstaffed", code: "9002")
    project.project_requirements.create!(certificate_type: certificate_types(:osha30))

    get project_compliance_path(project)

    assert_select "p", text: "No active crew assigned"
    assert_select "#compliance_matrix", count: 0
  end

  test "50 crew x 15 types renders with a bounded number of queries" do
    project = build_large_project(crew: 50, types: 15)
    sign_in_as users(:viewer)
    get project_compliance_path(projects(:closed_2390)) # warm up caches outside the count

    queries = count_queries { get project_compliance_path(project) }

    assert_response :success
    assert_select "#compliance_matrix tbody tr", 50
    assert_select "#compliance_matrix tbody td", 750
    assert_select "#compliance_matrix td[data-status=missing]", minimum: 1
    assert_select "#compliance_matrix td[data-status=fake]", minimum: 1
    assert_select "#compliance_matrix td[data-status=valid] [data-authenticity-review]", minimum: 1
    assert_operator queries, :>=, 4, "the counter should see the report's queries"
    assert_operator queries, :<=, 12, "expected a fixed number of queries, got #{queries}"

    small_queries = count_queries { get project_compliance_path(@project) }
    assert_equal small_queries, queries, "query count should not grow with the number of crew or types"
  end

  private
    # What the panel's "Not found" and "Doesn't match" buttons record.
    def confirm_fake(certificate, status = :not_found)
      flag_for_review(certificate, status, method: Authenticity::PERSON_METHOD)
    end

    # An automatic check's (or a QR code's) result: the certificate still counts by its dates.
    def flag_for_review(certificate, status = :not_found, method: "automatic:aha_ecards")
      certificate.update_columns(authenticity_status: Certificate.authenticity_statuses.fetch(status), authenticity_method: method)
    end

    # Counts query-cache hits too: the test connection is pinned, so the cache can
    # outlive a request and would otherwise hide repeated queries.
    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    # Bulk rows via insert_all so the setup stays fast. Statuses cycle through every value.
    def build_large_project(crew:, types:)
      today = Date.current
      project = Project.create!(name: "Big build", code: "BIG", starts_on: today - 10, ends_on: today + 200)
      type_rows = Array.new(types) { |i| { name: "Bulk type #{i}", code: "BULK#{i}", validity_months: 24, position: 200 + i } }
      type_ids = CertificateType.insert_all!(type_rows, returning: :id).rows.flatten
      ProjectRequirement.insert_all!(type_ids.map { |id| { project_id: project.id, certificate_type_id: id } })

      role_id = crew_roles(:laborer).id
      member_rows = Array.new(crew) { |i| { first_name: "Person#{i}", last_name: "Bulk#{format("%02d", i)}", crew_role_id: role_id } }
      member_ids = CrewMember.insert_all!(member_rows, returning: :id).rows.flatten
      ProjectAssignment.insert_all!(member_ids.map { |id| { project_id: project.id, crew_member_id: id } })

      expiries = [ nil, today - 5, today + 10, today + 60, today + 400 ] # nil = missing
      authenticity_statuses = Certificate.authenticity_statuses.values # confirmed fake and flagged for review cells too
      certificate_rows = member_ids.each_with_index.flat_map do |member_id, i|
        type_ids.each_with_index.filter_map do |type_id, j|
          expires_on = expiries[(i + j) % expiries.size] or next
          { crew_member_id: member_id, certificate_type_id: type_id, completed_on: today - 700, expires_on: expires_on,
            expires_on_source: Certificate.expires_on_sources[:computed], source: Certificate.sources[:manual],
            authenticity_status: authenticity_statuses[(i + (2 * j)) % authenticity_statuses.size],
            authenticity_method: j.even? ? Authenticity::PERSON_METHOD : "automatic:aha_ecards" }
        end
      end
      Certificate.insert_all!(certificate_rows)
      project
    end
end
