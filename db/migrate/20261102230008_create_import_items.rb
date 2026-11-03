class CreateImportItems < ActiveRecord::Migration[8.1]
  def change
    create_table :import_items do |t|
      t.references :import_batch, null: false, foreign_key: { on_delete: :cascade }
      t.string :original_filename
      t.string :page_range # "1-2"; null for single images
      t.string :sha256 # of the original file
      t.integer :status, null: false, default: 0 # pending
      t.text :extracted_text
      t.jsonb :extraction
      t.decimal :confidence, precision: 3, scale: 2
      t.string :holder_name_raw
      t.string :certificate_name_raw
      t.references :matched_crew_member, foreign_key: { to_table: :crew_members, on_delete: :restrict }
      t.references :matched_certificate_type, foreign_key: { to_table: :certificate_types, on_delete: :restrict }
      t.date :proposed_completed_on
      t.date :proposed_expires_on
      t.string :proposed_certificate_number # encrypted (deterministic)
      t.string :provider # workers_ai | ollama | anthropic
      t.integer :ai_units_used
      t.bigint :certificate_id # FK added once certificates exists
      t.references :reviewed_by, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :reviewed_at
      t.text :error_message
      t.references :duplicate_of, foreign_key: { to_table: :import_items, on_delete: :nullify } # link to the original

      t.timestamps
    end
    add_index :import_items, :certificate_id
    add_index :import_items, :status
    # Not unique: duplicates are stored too, with status duplicate and duplicate_of_id set.
    add_index :import_items, %i[sha256 page_range]
  end
end
