require "test_helper"
require_relative "../services/imports/match_test_support"
require Rails.root.join("db/migrate/20261107120000_rematch_waiting_imports_ignoring_middle_names")

class RematchWaitingImportsIgnoringMiddleNamesTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  test "matches waiting cards that only missed by a middle name and leaves picked ones alone" do
    shamel = CrewMember.create!(first_name: "Shamel", last_name: "Deshawn Ferebee")
    suggested = review_item(member: shamel, holder_name_raw: "Shamel Ferebee", person_match: :suggested)
    unmatched = review_item(member: nil, holder_name_raw: "SHAMEL FEREBEE", person_match: :unmatched)
    picked = review_item(member: crew_members(:juan_ortiz), holder_name_raw: "Shamel Ferebee", person_match: :picked)

    ActiveRecord::Migration.suppress_messages { RematchWaitingImportsIgnoringMiddleNames.new.up }

    assert_equal [ shamel ], CrewMember.where(first_name: "Shamel").to_a # no second Shamel

    [ suggested, unmatched ].each do |item|
      assert_equal [ shamel, "matched" ], item.reload.then { [ _1.matched_crew_member, _1.person_match ] }
    end
    assert_equal [ crew_members(:juan_ortiz), "picked" ], picked.reload.then { [ _1.matched_crew_member, _1.person_match ] }
  end
end
