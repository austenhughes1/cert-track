# A fingerprint of what a file shows, so a re-saved copy of an earlier upload is caught before any AI
# call (owner, Nov 6, 2026: no paying to read the same certificate twice).
class AddContentDigestToImportItems < ActiveRecord::Migration[8.1]
  def change
    add_column :import_items, :content_digest, :string
    add_index :import_items, :content_digest
  end
end
