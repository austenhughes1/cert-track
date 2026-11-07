# Files read before new crew members, types and issuers were created automatically are waiting in
# the review queue unmatched. Gives them the same treatment from what was already read, with no new
# AI call. One that fails is left for a person, as it was.
class CreateMissingRecordsForWaitingImports < ActiveRecord::Migration[8.1]
  def up
    ImportItem.where(status: :needs_review).find_each do |item|
      Imports::CreateMissingRecords.new(item).call
    rescue ActiveRecord::ActiveRecordError => error
      say "import item #{item.id} left as it was: #{error.class.name}"
    end
  end

  def down
    # Records created here may already hold certificates.
  end
end
