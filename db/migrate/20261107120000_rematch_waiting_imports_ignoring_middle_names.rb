# Cards waiting in the review queue that didn't match their crew member only because one printed a
# middle name and the other didn't ("Shamel Ferebee" against "Shamel Deshawn Ferebee") are matched
# again with Imports::PersonMatcher's middle-name rule, from what was already read (no new AI call).
# Only items nobody matched or picked by hand; anything still unmatched gets the usual
# Imports::CreateMissingRecords. One that fails is left for a person, as it was.
class RematchWaitingImportsIgnoringMiddleNames < ActiveRecord::Migration[8.1]
  def up
    ImportItem.where(status: :needs_review, person_match: %i[unmatched suggested]).where.not(holder_name_raw: [ nil, "" ]).find_each do |item|
      found = Imports::PersonMatcher.new(item.holder_name_raw).call
      if found.match == :matched
        item.update!(matched_crew_member: found.crew_member, person_match: :matched, person_suggestions: found.suggestions)
      else
        Imports::CreateMissingRecords.new(item).call
      end
    rescue ActiveRecord::ActiveRecordError => error
      say "import item #{item.id} left as it was: #{error.class.name}"
    end
  end

  def down
    # Matches made here are what a fresh reading would make now.
  end
end
