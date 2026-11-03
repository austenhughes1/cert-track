class CreateAiUsageDays < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_usage_days do |t|
      t.date :day, null: false
      t.string :provider, null: false
      t.integer :units_used, null: false, default: 0
      t.integer :requests, null: false, default: 0

      t.timestamps
    end
    add_index :ai_usage_days, %i[day provider], unique: true
  end
end
