require "test_helper"
require_relative "match_test_support"

class Imports::CreateCrewMemberTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  def suggested(raw)
    Imports::CreateCrewMember.suggested_attributes(ImportItem.new(holder_name_raw: raw))
  end

  test "suggested_attributes reads first and last name from the printed holder name" do
    assert_equal({ first_name: "Juan", last_name: "Ortiz" }, suggested("ORTIZ, JUAN A"))
    assert_equal({ first_name: "Juan", last_name: "Ortiz" }, suggested("Juan A. Ortiz"))
    assert_equal({ first_name: "Maria", last_name: "Garcia Lopez" }, suggested("Maria Garcia Lopez"))
    assert_equal({ first_name: "Shea", last_name: "O'Brien" }, suggested("SHEA O'BRIEN"))
    assert_equal({ first_name: "Ana", last_name: "Ruiz-Peña" }, suggested("ana ruiz-peña"))
    assert_equal({ first_name: "Li", last_name: "Chen" }, suggested("Chen, Li"))
    assert_equal({ first_name: "McKenzie", last_name: "DeLeon" }, suggested("McKenzie DeLeon"))
    assert_equal({ first_name: "Juan", last_name: "O." }, suggested("Juan O."))
    assert_equal({ first_name: "Ortiz", last_name: "" }, suggested("ORTIZ"))
    assert_equal({ first_name: "", last_name: "" }, suggested(nil))
  end

  test "creates the member and matches the item to them" do
    item = review_item(member: nil, holder_name_raw: "Xavier Q. Wolfe",
      person_suggestions: [ { "id" => crew_members(:li_chen).id, "name" => "Li Chen", "similarity" => 0.2 } ])

    member = Imports::CreateCrewMember.new(item, user: users(:manager), attributes: ActionController::Parameters.new(
      first_name: "Xavier", last_name: "Wolfe", employer: "Example Tower Co", crew_role_id: crew_roles(:climber).id, active: "0"
    ).permit!).call

    assert member.persisted?
    assert member.active?
    assert_equal [ "Xavier", "Wolfe", "Example Tower Co", crew_roles(:climber) ], [ member.first_name, member.last_name, member.employer, member.crew_role ]
    item.reload
    assert_equal member, item.matched_crew_member
    assert item.person_matched?
    assert_equal [ member.id, crew_members(:li_chen).id ], item.person_suggestions.map { _1["id"] }
    assert item.needs_review?
  end

  test "accepting afterwards learns the printed spelling" do
    item = review_item(member: nil, holder_name_raw: "WOLFE, XAVIER Q")
    member = Imports::CreateCrewMember.new(item, user: users(:manager), attributes: { first_name: "Xavi", last_name: "Wolfe" }).call

    Imports::Accept.new(item.reload, user: users(:manager)).call

    assert_equal [ "WOLFE, XAVIER Q" ], member.reload.name_aliases
  end

  test "invalid attributes raise and change nothing" do
    item = review_item(member: nil)

    assert_no_difference -> { CrewMember.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        Imports::CreateCrewMember.new(item, user: users(:manager), attributes: { first_name: "Xavier" }).call
      end
    end
    assert_nil item.reload.matched_crew_member
  end

  test "only for review-queue items" do
    item = review_item(member: nil, status: :accepted)

    assert_raises(Imports::Accept::NotReviewable) do
      Imports::CreateCrewMember.new(item, user: users(:manager), attributes: { first_name: "A", last_name: "B" }).call
    end
  end
end
