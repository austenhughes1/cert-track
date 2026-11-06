# A flag when a certificate's image is too small or blurry to read (owner, Nov 5, 2026). unread_qr_pages
# and ocr_pages are what the text step found; quality_flags is the verdict.
class AddImageQualityFlags < ActiveRecord::Migration[8.1]
  def change
    change_table :import_items, bulk: true do |t|
      t.integer :unread_qr_pages, array: true, default: [], null: false
      t.integer :ocr_pages, array: true, default: [], null: false
      t.jsonb :quality_flags, default: [], null: false
    end
    add_column :certificates, :quality_flags, :jsonb, default: [], null: false
  end
end
