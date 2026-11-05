# Phase 3b (docs/PLAN.md): certificate issuers, and each certificate's verification code, link and
# authenticity check. Production's database already exists, so the default issuers from
# config/certificate_issuers.yml are inserted here as well as by db/seeds.rb.
class CreateCertificateIssuersAndVerification < ActiveRecord::Migration[8.1]
  def up
    create_table :certificate_issuers do |t|
      t.citext :name, null: false
      t.string :code, null: false
      t.string :aliases, array: true, default: [], null: false
      t.string :domains, array: true, default: [], null: false
      t.integer :verification_method, default: 0, null: false
      t.string :lookup_url
      t.string :link_template
      t.string :automatic_check
      t.text :verification_notes
      t.boolean :active, default: true, null: false
      t.integer :position
      t.timestamps
    end
    add_index :certificate_issuers, :name, unique: true
    add_index :certificate_issuers, :code, unique: true
    add_index :certificate_issuers, :domains, using: :gin

    change_table :certificates, bulk: true do |t|
      t.references :certificate_issuer, foreign_key: true
      t.text :verification_code # encrypted
      t.text :verification_url # encrypted
      t.integer :authenticity_status, default: 0, null: false
      t.datetime :authenticity_checked_at
      t.references :authenticity_checked_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :authenticity_method
      t.text :authenticity_note
      t.jsonb :authenticity_details, default: {}, null: false
    end
    add_index :certificates, :authenticity_status, where: "superseded_at IS NULL", name: "index_certificates_on_authenticity_status_current"

    change_table :import_items, bulk: true do |t|
      t.references :matched_certificate_issuer, foreign_key: { to_table: :certificate_issuers }
      t.integer :issuer_match, default: 0, null: false
      t.jsonb :issuer_suggestions, default: [], null: false
      t.text :proposed_verification_code # encrypted
      t.text :proposed_verification_url # encrypted
      t.text :barcodes # encrypted JSON array of { "page" =>, "text" => }
      t.integer :authenticity_status, default: 0, null: false
      t.datetime :authenticity_checked_at
      t.references :authenticity_checked_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :authenticity_method
      t.text :authenticity_note
      t.jsonb :authenticity_details, default: {}, null: false
    end

    seed_default_issuers
  end

  def down
    change_table :import_items, bulk: true do |t|
      t.remove_references :matched_certificate_issuer, foreign_key: { to_table: :certificate_issuers }
      t.remove_references :authenticity_checked_by, foreign_key: { to_table: :users }
      t.remove :issuer_match, :issuer_suggestions, :proposed_verification_code, :proposed_verification_url, :barcodes,
        :authenticity_status, :authenticity_checked_at, :authenticity_method, :authenticity_note, :authenticity_details
    end
    remove_index :certificates, name: "index_certificates_on_authenticity_status_current"
    change_table :certificates, bulk: true do |t|
      t.remove_references :certificate_issuer, foreign_key: true
      t.remove_references :authenticity_checked_by, foreign_key: { to_table: :users }
      t.remove :verification_code, :verification_url, :authenticity_status, :authenticity_checked_at,
        :authenticity_method, :authenticity_note, :authenticity_details
    end
    drop_table :certificate_issuers
  end

  private
    METHODS = { "unknown" => 0, "qr_or_code" => 1, "code_lookup" => 2, "contact" => 3, "no_registry" => 4 }.freeze

    # Plain SQL so the migration doesn't depend on the CertificateIssuer model as it later changes.
    def seed_default_issuers
      now = connection.quote(Time.current)
      YAML.safe_load_file(Rails.root.join("config/certificate_issuers.yml")).each.with_index(1) do |issuer, position|
        values = [
          issuer.fetch("name"), issuer.fetch("code"), pg_array(issuer["aliases"]), pg_array(issuer["domains"]),
          METHODS.fetch(issuer.fetch("verification_method", "unknown")), issuer["lookup_url"], issuer["link_template"],
          issuer["automatic_check"], issuer["verification_notes"], true, position
        ].map { |value| connection.quote(value) }
        execute <<~SQL.squish
          INSERT INTO certificate_issuers (name, code, aliases, domains, verification_method, lookup_url, link_template,
            automatic_check, verification_notes, active, position, created_at, updated_at)
          VALUES (#{values.join(", ")}, #{now}, #{now})
          ON CONFLICT (code) DO NOTHING
        SQL
      end
    end

    def pg_array(values)
      PG::TextEncoder::Array.new.encode(Array(values).map(&:to_s))
    end
end
