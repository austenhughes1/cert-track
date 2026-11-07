# A crew member added automatically from a card whose name was close to someone already on file
# (CrewMembers::DuplicateFinder) points at them, for the crew page's possible duplicates and Merge.
class AddPossibleDuplicateOfToCrewMembers < ActiveRecord::Migration[8.1]
  def change
    add_reference :crew_members, :possible_duplicate_of, foreign_key: { to_table: :crew_members, on_delete: :nullify }
  end
end
