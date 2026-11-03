# Phase 3 pipeline state that the sketch in docs/PLAN.md leaves implicit:
# match quality and suggestions for the review queue, the proposed expiry source,
# the source file an item was split from, and budget rescheduling.
class AddPipelineFieldsToImports < ActiveRecord::Migration[8.1]
  def change
    change_table :import_items, bulk: true do |t|
      t.integer :person_match, null: false, default: 0 # unmatched | suggested | matched
      t.integer :type_match, null: false, default: 0   # unmatched | suggested | matched
      t.jsonb :person_suggestions, null: false, default: []
      t.jsonb :type_suggestions, null: false, default: []
      t.string :issuer_raw
      t.integer :proposed_expires_on_source # printed | computed | none
      t.references :source_item, null: true, foreign_key: { to_table: :import_items, on_delete: :cascade }
      t.string :rejection_reason
      t.datetime :skipped_at
      t.datetime :next_attempt_at
      t.integer :attempts, null: false, default: 0
    end

    change_table :import_batches, bulk: true do |t|
      t.text :error_message
      t.datetime :summary_sent_at
    end
  end
end
