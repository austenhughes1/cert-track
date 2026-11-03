# Durable per-day email counter backing the 90/day guard under Resend's 100/day cap.
class CreateEmailSendDays < ActiveRecord::Migration[8.1]
  def change
    create_table :email_send_days do |t|
      t.date :day, null: false
      t.integer :sent_count, null: false, default: 0
      t.integer :deferred_count, null: false, default: 0 # sends held back by the cap; drives the dashboard banner
      t.timestamps
    end
    add_index :email_send_days, :day, unique: true
  end
end
