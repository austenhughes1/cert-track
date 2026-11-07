# Two changes for crew already on file (owner, Nov 7, 2026):
# - every member is marked a possible duplicate of the closest earlier member, if one is close
#   (CrewMembers::DuplicateFinder), so the crew page lists them for Merge;
# - cards waiting in the review queue that nobody matched or picked get the new rule: a close
#   spelling is matched, anything else gets its own crew member (Imports::CreateMissingRecords),
#   from what was already read (no new AI call).
# One that fails is left as it was.
class MarkPossibleDuplicateCrewMembers < ActiveRecord::Migration[8.1]
  def up
    CrewMember.reset_column_information
    CrewMember.where(possible_duplicate_of_id: nil).order(:id).find_each do |member|
      duplicate = CrewMembers::DuplicateFinder.new(member.full_name, except: member).call
      member.update_columns(possible_duplicate_of_id: duplicate.id) if duplicate && duplicate.id < member.id
    end

    ImportItem.where(status: :needs_review, person_match: %i[unmatched suggested]).find_each do |item|
      Imports::CreateMissingRecords.new(item).call
    rescue ActiveRecord::ActiveRecordError => error
      say "import item #{item.id} left as it was: #{error.class.name}"
    end
  end

  def down
    # Members added here may already hold certificates; the marks go with the column.
  end
end
