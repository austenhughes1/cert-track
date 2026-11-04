require "test_helper"

class AskControllerTest < ActionDispatch::IntegrationTest
  test "requires sign-in" do
    get ask_path(q: "Does Juan have OSHA 30?")

    assert_redirected_to new_session_path
  end

  test "every role can ask" do
    %i[viewer manager admin].each do |role|
      sign_in_as users(role)

      get ask_path
      assert_response :success, "#{role} should see the Ask page"
      assert_select "title", "Ask · CertTrack"

      get ask_path(q: "Does Juan Ortiz have OSHA 30?")
      assert_response :success, "#{role} should get an answer"
      assert_select "#ask_answer[data-status=yes]"
      sign_out
    end
  end

  test "a blank question shows the question box, example chips and help, and no answer" do
    sign_in_as users(:viewer)

    get ask_path

    assert_select "form#ask_form[method=get][action=?]", ask_path do
      assert_select "input[type=search][name=q][autofocus]"
    end
    examples = css_select("#ask_examples a")
    assert_equal 5, examples.size
    assert_select "#ask_examples a[href=?]", ask_path(q: "Who has Flagger?"), text: "Who has Flagger?"
    assert_select "#ask_help"
    assert_select "#ask_answer", count: 0
  end

  test "whitespace-only questions count as blank" do
    sign_in_as users(:viewer)

    get ask_path(q: "   ")

    assert_select "#ask_answer", count: 0
    assert_select "#ask_help"
  end

  test "a yes answer links the certificate and the person" do
    sign_in_as users(:viewer)
    juan = crew_members(:juan_ortiz)

    get ask_path(q: "Does Juan Ortiz have OSHA 30?")

    assert_select "#ask_answer[data-intent=check][data-status=yes]" do
      assert_select "[data-status=yes]", text: "Yes"
      assert_select "#ask_answer_text", text: /\AYes\. Juan Ortiz has OSHA 30 Construction, completed .*, no expiration\.\z/
      assert_select "#ask_check_links a[href=?]", crew_member_certificate_path(juan, certificates(:juan_osha30)), text: "View certificate"
      assert_select "#ask_check_links a[href=?]", crew_member_path(juan), text: "View Juan Ortiz"
    end
    assert_select "input[name=q][value=?]", "Does Juan Ortiz have OSHA 30?"
    assert_select "input[name=q][autofocus]", count: 0
  end

  test "a no answer without a certificate links the person only" do
    sign_in_as users(:viewer)

    get ask_path(q: "Has Mari got her flagger?")

    assert_select "#ask_answer[data-status=no]"
    assert_select "#ask_check_links a", count: 1
    assert_select "#ask_check_links a[href=?]", crew_member_path(crew_members(:maria_garcia))
  end

  test "a list answer shows evidence rows with status badges and view links" do
    sign_in_as users(:viewer)
    flagger = certificate_types(:flagger)

    get ask_path(q: "Who has flagger?")

    assert_select "#ask_answer[data-intent=list_holders][data-status=list]"
    assert_select "#ask_section_current h2", text: /Current\s+\(3\)/
    assert_select "#ask_section_current tbody tr", 3
    assert_select "#ask_section_inactive tbody tr", 1
    assert_select "#ask_section_current th", text: "Certificate", count: 0 # one type: no type column
    juan_flagger = certificates(:juan_flagger)
    assert_select "#ask_section_current tr[data-crew-member-id='#{crew_members(:juan_ortiz).id}'][data-certificate-type-id='#{flagger.id}']" do
      assert_select "a[href=?]", crew_member_path(crew_members(:juan_ortiz)), text: "Juan Ortiz"
      assert_select "[data-status=expiring]"
      assert_select "a[href=?]", crew_member_certificate_path(crew_members(:juan_ortiz), juan_flagger), text: "View"
    end
    assert_select "#ask_section_inactive", text: /Inactive/
  end

  test "who doesn't have a type lists the people without it, not the holders" do
    sign_in_as users(:viewer)

    get ask_path(q: "Who doesn't have flagger?")

    assert_select "#ask_answer[data-intent=lacking][data-status=list]"
    assert_select "#ask_section_lacking h2", text: /No current Flagger\s+\(1\)/
    assert_select "#ask_section_lacking tbody tr", 1
    assert_select "#ask_section_lacking tr[data-crew-member-id='#{crew_members(:maria_garcia).id}'] [data-status=missing]"
    assert_select "#ask_section_lacking tr[data-crew-member-id='#{crew_members(:juan_ortiz).id}']", count: 0
    assert_select "#ask_section_lacking th", text: "Certificate", count: 0
  end

  test "what has expired lists the expired certificates" do
    sign_in_as users(:viewer)

    get ask_path(q: "What has expired?")

    assert_select "#ask_answer[data-intent=expired][data-status=list]"
    assert_select "#ask_answer_text", /\A2 certificates have expired: Mari Garcia's First Aid/
    assert_select "#ask_section_expired tbody tr [data-status=expired]", 2
    assert_select "#ask_section_expired a[href=?]", crew_member_certificate_path(crew_members(:li_chen), certificates(:li_first_aid))
  end

  test "a person's list hides the person column" do
    sign_in_as users(:viewer)

    get ask_path(q: "What does Juan Ortiz have?")

    assert_select "#ask_section_certificates tbody tr", 4
    assert_select "#ask_section_certificates th", text: "Person", count: 0
    assert_select "#ask_section_certificates th", text: "Certificate"
  end

  test "gaps link people without a certificate to their page" do
    sign_in_as users(:viewer)
    tower = projects(:tower_2417)

    get ask_path(q: "What's missing on 2417?")

    assert_select "#ask_section_project_#{tower.id} h2", text: /2417 · Tower 2417 Upgrade/
    assert_select "#ask_section_project_#{tower.id} tbody tr", 5
    assert_select "#ask_section_project_#{tower.id} tr[data-crew-member-id='#{crew_members(:dave_miller).id}']" do
      assert_select "[data-status=missing]"
      assert_select "a[href=?]", crew_member_path(crew_members(:dave_miller)), text: "View"
    end
  end

  test "a requirements question lists the requirements, then who is missing what" do
    sign_in_as users(:viewer)
    tower = projects(:tower_2417)

    get ask_path(q: "What's required on 2417?")

    assert_select "#ask_answer[data-intent=requirements][data-status=list]"
    assert_select "#ask_answer_text", text: /\A2417 · Tower 2417 Upgrade requires 5 certificate types: .*3 of 4 assigned crew are missing at least one/
    assert_select "#ask_section_requirements h2", text: /Requirements\s+\(5\)/
    assert_select "#ask_section_requirements tbody tr", 5
    assert_select "#ask_section_requirements tr[data-certificate-type-id='#{certificate_types(:climber).id}']" do
      assert_select "td", text: "Climber"
      assert_select "td[data-missing='1']", text: "1 of 2 missing"
      assert_select "p", text: "Anyone working above 6 ft on the tower."
    end
    assert_select "#ask_section_requirements tr[data-certificate-type-id='#{certificate_types(:cdl_a).id}'] td", text: "All current (1)"
    assert_select "#ask_section_requirements a[href=?]", project_compliance_path(tower), text: "View the compliance matrix"
    assert_select "#ask_section_gaps tbody tr", 5
    assert_select "#ask_section_gaps th", text: "Person"
  end

  test "a project chip names the project once" do
    sign_in_as users(:viewer)

    get ask_path(q: "what's missing on 2471")

    assert_select "#ask_answer[data-status=not_found]"
    assert_select "#ask_candidates a[href=?]", ask_path(q: "what's missing on 2417", project_id: projects(:tower_2417).id) do
      assert_select "span", count: 1
      assert_select "span", text: "2417 · Tower 2417 Upgrade"
    end
  end

  test "an unrelated word in an expiry question gets the answer, not a project chip" do
    sign_in_as users(:viewer)

    get ask_path(q: "what has expired so far")

    assert_select "#ask_answer[data-intent=expired][data-status=list]"
    assert_select "#ask_candidates", count: 0
    assert_select "#ask_notes li", text: "Ignored “so far”."
  end

  test "ambiguous people are offered as links that re-ask pinned to the choice" do
    juana = CrewMember.create!(first_name: "Juana", last_name: "Ortega")
    sign_in_as users(:viewer)

    get ask_path(q: "Does Juan Orteg have OSHA 30?")

    assert_select "#ask_answer[data-status=ambiguous]"
    assert_select "#ask_answer_text", text: /\ADid you mean .*Juana Ortega.*\?\z/
    href = ask_path(q: "Does Juana Ortega have OSHA 30?", crew_member_id: juana.id)
    assert_select "#ask_candidates a[href=?]", href, text: /Juana Ortega/

    get href
    assert_select "#ask_answer[data-status=no]"
    assert_select "#ask_answer_text", text: "No. Juana Ortega has no OSHA 30 Construction certificate on file."
  end

  test "unknown questions get help text" do
    sign_in_as users(:viewer)

    get ask_path(q: "asdf qwerty")

    assert_select "#ask_answer[data-status=unknown]", text: /Try one of the examples/
    assert_select "#ask_examples a", 5
  end

  test "notes explain loose matches" do
    sign_in_as users(:viewer)

    get ask_path(q: "does jaun ortis have flagger")

    assert_select "#ask_notes li", text: "Matched “jaun ortis” to Juan Ortiz."
  end

  test "pins that aren't ids are ignored" do
    sign_in_as users(:viewer)

    get ask_path(q: "Does Juan have flagger?", crew_member_id: "abc", certificate_type_id: "1 OR 1=1")

    assert_response :success
    assert_select "#ask_check_links a[href=?]", crew_member_path(crew_members(:juan_ortiz))
  end

  test "overlong questions are cut short" do
    sign_in_as users(:viewer)

    get ask_path(q: "Does Juan have flagger? #{"x" * 1000}")

    assert_response :success
    assert_select "input[name=q][maxlength=?]", Ask::Question::MAX_LENGTH.to_s
    assert_operator css_select("input[name=q]").first["value"].length, :<=, Ask::Question::MAX_LENGTH
  end

  test "the page runs a bounded number of queries" do
    sign_in_as users(:viewer)
    get ask_path # warm up

    {
      ask_path => 6,
      ask_path(q: "Does Juan Ortiz have OSHA 30?") => 10,
      ask_path(q: "Who has flagger?") => 10,
      ask_path(q: "What's missing on 2417?") => 11,
      ask_path(q: "What's required on 2417?") => 12,
      ask_path(q: "missing") => 11
    }.each do |path, limit|
      queries = count_queries { get path }
      assert_response :success
      assert_operator queries, :<=, limit, "#{path} ran #{queries} queries"
    end
  end

  private
    # Integration requests share the test's pinned connection, whose query cache
    # survives between requests until a write, so clear it to count real queries.
    def count_queries(&block)
      ActiveRecord::Base.connection_pool.clear_query_cache
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
