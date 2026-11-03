class CreateCrewRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :crew_roles do |t|
      t.citext :name, null: false

      t.timestamps
    end
    add_index :crew_roles, :name, unique: true
  end
end
