# A lasting record of each compliance packet build. The zip (projects.packet) is deleted
# 7 days after it is built; this row and its attached index.pdf stay.
class CreatePacketBuilds < ActiveRecord::Migration[8.1]
  def change
    create_table :packet_builds do |t|
      t.references :project, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :built_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :built_at, null: false
      t.string :packet_filename, null: false
      t.integer :certificate_count, null: false, default: 0
      t.integer :file_count, null: false, default: 0
      t.integer :gap_count, null: false, default: 0

      t.timestamps
    end
    add_index :packet_builds, %i[project_id built_at]
  end
end
