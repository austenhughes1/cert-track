class CreateProjectRequirements < ActiveRecord::Migration[8.1]
  def change
    create_table :project_requirements do |t|
      t.references :project, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :certificate_type, null: false, foreign_key: { on_delete: :restrict }
      t.references :crew_role, foreign_key: { on_delete: :restrict } # null = everyone on the project
      t.text :notes

      t.timestamps
    end
    # NULLS NOT DISTINCT (PG15+) so a null crew_role_id ("everyone") can only appear once per type.
    add_index :project_requirements, %i[project_id certificate_type_id crew_role_id],
      unique: true, nulls_not_distinct: true, name: "index_project_requirements_uniqueness"
  end
end
