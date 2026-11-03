class CreateImportBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :import_batches do |t|
      t.references :uploaded_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :status, null: false, default: 0 # receiving
      t.integer :files_count, null: false, default: 0
      t.integer :items_count, null: false, default: 0
      t.integer :accepted_count, null: false, default: 0
      t.integer :review_count, null: false, default: 0
      t.integer :error_count, null: false, default: 0

      t.timestamps
    end
    add_index :import_batches, :status
  end
end
