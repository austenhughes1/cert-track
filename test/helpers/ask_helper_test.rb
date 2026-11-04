require "test_helper"

class AskHelperTest < ActionView::TestCase
  def fragment(html)
    Nokogiri::HTML5.fragment(html)
  end

  test "status labels and badges" do
    assert_equal "Yes", ask_status_label(:yes)
    assert_equal "Which one?", ask_status_label("ambiguous")

    badge = fragment(ask_status_badge(:no)).at_css("span")
    assert_equal "No", badge.text
    assert_equal "no", badge["data-status"]
    assert_includes badge["class"], "bg-red-600"
  end

  test "every status has a label, card and badge" do
    AskQuery::STATUSES.each do |status|
      assert ask_status_label(status)
      assert ask_card_classes(status)
      assert fragment(ask_status_badge(status)).at_css("span")
    end
  end

  test "ask_candidate_path re-asks with the pin" do
    candidate = Ask::Candidate.new(record: crew_members(:li_chen), label: "Li Chen", detail: "", question: "Does Li Chen have flagger?")

    assert_equal ask_path(q: "Does Li Chen have flagger?", crew_member_id: crew_members(:li_chen).id), ask_candidate_path(candidate)
  end

  test "ask_relative_expiry" do
    today = Date.new(2026, 11, 3)

    assert_equal "in 10 days", ask_relative_expiry(Date.new(2026, 11, 13), today: today)
    assert_equal "today", ask_relative_expiry(today, today: today)
    assert_equal "tomorrow", ask_relative_expiry(today + 1, today: today)
    assert_equal "1 day ago", ask_relative_expiry(today - 1, today: today)
    assert_equal "5 days ago", ask_relative_expiry(today - 5, today: today)
    assert_nil ask_relative_expiry(nil, today: today)
  end

  test "ask_check_links links the certificate and the person" do
    result = AskQuery.new("Does Juan have OSHA 30?", user: users(:viewer)).call
    links = fragment(ask_check_links(result)).css("a")

    assert_equal [ "View certificate", "View Juan Ortiz" ], links.map(&:text)
    assert_equal crew_member_certificate_path(crew_members(:juan_ortiz), certificates(:juan_osha30)), links.first["href"]
  end

  test "ask_check_links without a certificate links the person only" do
    result = AskQuery.new("Does Mari have flagger?", user: users(:viewer)).call

    assert_equal [ "View Mari Garcia" ], fragment(ask_check_links(result)).css("a").map(&:text)
  end

  test "ask_requirement_roles and ask_requirement_coverage" do
    requirement = Ask::Requirement.new(certificate_type: certificate_types(:flagger), crew_roles: [], notes: [], needed: 4, missing: 1)

    assert_equal "Everyone", ask_requirement_roles(requirement)
    assert_equal "Climber, Operator", ask_requirement_roles(requirement.with(crew_roles: [ crew_roles(:climber), crew_roles(:operator) ]))
    assert_equal "1 of 4 missing", ask_requirement_coverage(requirement)
    assert_equal "All current (4)", ask_requirement_coverage(requirement.with(missing: 0))
    assert_equal "Nobody needs it", ask_requirement_coverage(requirement.with(needed: 0, missing: 0))
  end

  test "ask_columns drops the column every row shares" do
    holders = AskQuery.new("Who has flagger?", user: users(:viewer)).call
    assert_equal({ person: true, certificate_type: false }, ask_columns(holders))

    list = AskQuery.new("What does Juan have?", user: users(:viewer)).call
    assert_equal({ person: false, certificate_type: true }, ask_columns(list))

    expiring = AskQuery.new("What does Juan have expiring in 90 days?", user: users(:viewer)).call
    assert_equal({ person: false, certificate_type: true }, ask_columns(expiring))

    gaps = AskQuery.new("missing", user: users(:viewer)).call
    assert_equal({ person: true, certificate_type: true }, ask_columns(gaps))

    lacking = AskQuery.new("Who doesn't have flagger?", user: users(:viewer)).call
    assert_equal({ person: true, certificate_type: false }, ask_columns(lacking))

    expired = AskQuery.new("Whose first aid is expired?", user: users(:viewer)).call
    assert_equal({ person: true, certificate_type: false }, ask_columns(expired))

    requirements = AskQuery.new("What's required on 2417?", user: users(:viewer)).call
    assert_equal({ person: true, certificate_type: true }, ask_columns(requirements))
  end
end
