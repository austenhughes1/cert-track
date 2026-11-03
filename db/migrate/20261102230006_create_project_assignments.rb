class CreateProjectAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :project_assignments do |t|
      t.references :project, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :crew_member, null: false, foreign_key: { on_delete: :restrict }
      t.references :crew_role, foreign_key: { on_delete: :restrict } # null = member's own role
      t.date :starts_on
      t.date :ends_on

      t.timestamps
    end
    add_index :project_assignments, %i[project_id crew_member_id], unique: true
  end
end
