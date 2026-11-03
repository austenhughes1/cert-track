class CreateCrewMembers < ActiveRecord::Migration[8.1]
  def change
    create_table :crew_members do |t|
      t.string :first_name, null: false
      t.string :last_name, null: false
      t.string :preferred_name
      t.string :name_aliases, array: true, null: false, default: []
      t.citext :email
      t.string :phone
      t.string :employer
      t.references :crew_role, foreign_key: { on_delete: :restrict }
      t.boolean :active, null: false, default: true
      t.boolean :expiry_emails_opt_in, null: false, default: false
      t.text :notes

      t.timestamps
    end

    # Trigram search over the full name (CrewMember.search).
    add_index :crew_members, "lower(first_name || ' ' || last_name) gin_trgm_ops",
      using: :gin, name: "index_crew_members_on_full_name_trgm"
  end
end
