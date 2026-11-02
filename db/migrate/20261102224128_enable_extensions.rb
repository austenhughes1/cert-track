class EnableExtensions < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"  # case-insensitive emails and names
    enable_extension "pg_trgm" # fuzzy name and certificate-type matching
  end
end
