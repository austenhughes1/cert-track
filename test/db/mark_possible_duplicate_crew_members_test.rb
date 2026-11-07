require "test_helper"
require_relative "../services/imports/match_test_support"
require Rails.root.join("db/migrate/20261107140000_mark_possible_duplicate_crew_members")

class MarkPossibleDuplicateCrewMembersTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  test "marks later members close to an earlier one and gives fuzzy waiting cards their own member" do
    later = CrewMember.create!(first_name: "Juan", last_name: "Ortizes")
    waiting = review_item(member: crew_members(:juan_ortiz), holder_name_raw: "Jaun Ortis", person_match: :suggested)

    ActiveRecord::Migration.suppress_messages { MarkPossibleDuplicateCrewMembers.new.up }

    assert_equal crew_members(:juan_ortiz), later.reload.possible_duplicate_of
    assert_nil crew_members(:juan_ortiz).reload.possible_duplicate_of # the earlier one isn't marked
    assert_equal [ "Jaun Ortis", "matched" ], waiting.reload.then { [ it.matched_crew_member.full_name, it.person_match ] }
  end
end
