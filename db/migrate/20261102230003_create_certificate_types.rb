class CreateCertificateTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :certificate_types do |t|
      t.citext :name, null: false
      t.string :code, null: false
      t.string :issuing_body
      t.integer :validity_months # null = never expires
      t.string :aliases, array: true, null: false, default: []
      t.text :description
      t.boolean :active, null: false, default: true
      t.integer :position

      t.timestamps
    end
    add_index :certificate_types, :name, unique: true
    add_index :certificate_types, :code, unique: true
    add_index :certificate_types, :name, using: :gin, opclass: :gin_trgm_ops,
      name: "index_certificate_types_on_name_trgm"
  end
end
