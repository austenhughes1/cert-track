class CreateCertificates < ActiveRecord::Migration[8.1]
  def change
    create_table :certificates do |t|
      t.references :crew_member, null: false, index: false, foreign_key: { on_delete: :restrict }
      t.references :certificate_type, null: false, foreign_key: { on_delete: :restrict }
      t.string :certificate_number # encrypted (deterministic)
      t.string :issued_by
      t.date :completed_on, null: false
      t.date :expires_on
      t.integer :expires_on_source, null: false, default: 2 # manual
      t.integer :source, null: false, default: 0 # manual
      t.references :import_item, foreign_key: { on_delete: :restrict }
      t.references :verified_by, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :verified_at
      t.datetime :superseded_at
      t.text :notes

      t.timestamps
    end
    add_index :certificates, %i[crew_member_id certificate_type_id superseded_at],
      name: "index_certificates_on_member_type_superseded"
    add_index :certificates, :expires_on, where: "superseded_at IS NULL",
      name: "index_certificates_on_expires_on_current"
    # At most one current certificate per person and type.
    add_index :certificates, %i[crew_member_id certificate_type_id], unique: true,
      where: "superseded_at IS NULL", name: "index_certificates_one_current_per_member_type"

    add_foreign_key :import_items, :certificates, on_delete: :restrict
  end
end
