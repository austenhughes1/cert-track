class CreateExpiryNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :expiry_notifications do |t|
      t.references :certificate, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.integer :threshold, null: false
      t.citext :recipient_email, null: false
      t.datetime :sent_at

      t.timestamps
    end
    add_index :expiry_notifications, %i[certificate_id threshold recipient_email], unique: true,
      name: "index_expiry_notifications_uniqueness"
  end
end
