class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.string :code
      t.string :client
      t.string :location
      t.date :starts_on
      t.date :ends_on
      t.integer :status, null: false, default: 1 # active
      t.datetime :packet_built_at

      t.timestamps
    end
    add_index :projects, :code, unique: true
    add_index :projects, :status
  end
end
