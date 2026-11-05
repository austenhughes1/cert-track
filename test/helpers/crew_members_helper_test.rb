require "test_helper"

class CrewMembersHelperTest < ActionView::TestCase
  test "active filter options default to active members" do
    assert_equal [ [ "Active", "" ], [ "Inactive", "inactive" ], [ "Active and inactive", "all" ] ], crew_member_active_filter_options
  end

  test "status filter options cover every filterable status, most severe first" do
    assert_equal CrewMembersController::STATUS_FILTERS, crew_member_status_filter_options.map(&:last)
    assert_equal [ "Has confirmed fake", "fake" ], crew_member_status_filter_options.first
  end

  test "role filter options start with no role and use string ids" do
    options = crew_member_role_filter_options([ crew_roles(:climber), crew_roles(:foreman) ])

    assert_equal [ [ "No role", "none" ], [ "Climber", crew_roles(:climber).id.to_s ], [ "Foreman", crew_roles(:foreman).id.to_s ] ], options
  end

  test "filters count as applied when anything beyond the default is set" do
    assert_not crew_member_filters_applied?(q: "", active: "", employer: "", crew_role_id: "", status: "")
    assert crew_member_filters_applied?(q: "juan", active: "", employer: "", crew_role_id: "", status: "")
    assert crew_member_filters_applied?(q: "", active: "all", employer: "", crew_role_id: "", status: "")
    assert crew_member_filters_applied?(q: "", active: "", employer: "", crew_role_id: "", status: "expired")
  end

  test "aliases text puts one alias per line" do
    assert_equal "Jon Ortiz\nJuan Ortiz-Ruiz", crew_member_aliases_text(crew_members(:juan_ortiz))
    assert_equal "", crew_member_aliases_text(CrewMember.new)
  end

  test "contact links email and phone" do
    html = crew_member_contact(crew_members(:juan_ortiz))

    assert_includes html, %(href="mailto:juan.ortiz@example.com")
    assert_includes html, %(href="tel:3035550101")
    assert_includes html, "303-555-0101"
  end

  test "contact is a dash when there is neither email nor phone" do
    html = crew_member_contact(CrewMember.new(first_name: "No", last_name: "Contact"))

    assert_dom_equal %(<span class="text-gray-400">—</span>), html
  end
end
