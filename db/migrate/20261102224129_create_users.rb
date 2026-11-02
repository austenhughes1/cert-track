class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.citext :email_address, null: false
      t.string :password_digest, null: false
      t.string :name
      t.integer :role, null: false, default: 2 # viewer
      t.boolean :receives_digest, null: false, default: true

      t.timestamps
    end
    add_index :users, :email_address, unique: true
  end
end
