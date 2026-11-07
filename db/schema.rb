# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_07_140000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_usage_days", force: :cascade do |t|
    t.date "day", null: false
    t.string "provider", null: false
    t.integer "units_used", default: 0, null: false
    t.integer "requests", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day", "provider"], name: "index_ai_usage_days_on_day_and_provider", unique: true
  end

  create_table "certificate_issuers", force: :cascade do |t|
    t.citext "name", null: false
    t.string "code", null: false
    t.string "aliases", default: [], null: false, array: true
    t.string "domains", default: [], null: false, array: true
    t.integer "verification_method", default: 0, null: false
    t.string "lookup_url"
    t.string "link_template"
    t.string "automatic_check"
    t.text "verification_notes"
    t.boolean "active", default: true, null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_certificate_issuers_on_code", unique: true
    t.index ["domains"], name: "index_certificate_issuers_on_domains", using: :gin
    t.index ["name"], name: "index_certificate_issuers_on_name", unique: true
  end

  create_table "certificate_types", force: :cascade do |t|
    t.citext "name", null: false
    t.string "code", null: false
    t.string "issuing_body"
    t.integer "validity_months"
    t.string "aliases", default: [], null: false, array: true
    t.text "description"
    t.boolean "active", default: true, null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_certificate_types_on_code", unique: true
    t.index ["name"], name: "index_certificate_types_on_name", unique: true
    t.index ["name"], name: "index_certificate_types_on_name_trgm", opclass: :gin_trgm_ops, using: :gin
  end

  create_table "certificates", force: :cascade do |t|
    t.bigint "crew_member_id", null: false
    t.bigint "certificate_type_id", null: false
    t.string "certificate_number"
    t.string "issued_by"
    t.date "completed_on", null: false
    t.date "expires_on"
    t.integer "expires_on_source", default: 2, null: false
    t.integer "source", default: 0, null: false
    t.bigint "import_item_id"
    t.bigint "verified_by_id"
    t.datetime "verified_at"
    t.datetime "superseded_at"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "certificate_issuer_id"
    t.text "verification_code"
    t.text "verification_url"
    t.integer "authenticity_status", default: 0, null: false
    t.datetime "authenticity_checked_at"
    t.bigint "authenticity_checked_by_id"
    t.string "authenticity_method"
    t.text "authenticity_note"
    t.jsonb "authenticity_details", default: {}, null: false
    t.jsonb "quality_flags", default: [], null: false
    t.index ["authenticity_checked_by_id"], name: "index_certificates_on_authenticity_checked_by_id"
    t.index ["authenticity_status"], name: "index_certificates_on_authenticity_status_current", where: "(superseded_at IS NULL)"
    t.index ["certificate_issuer_id"], name: "index_certificates_on_certificate_issuer_id"
    t.index ["certificate_type_id"], name: "index_certificates_on_certificate_type_id"
    t.index ["crew_member_id", "certificate_type_id", "superseded_at"], name: "index_certificates_on_member_type_superseded"
    t.index ["crew_member_id", "certificate_type_id"], name: "index_certificates_one_current_per_member_type", unique: true, where: "(superseded_at IS NULL)"
    t.index ["expires_on"], name: "index_certificates_on_expires_on_current", where: "(superseded_at IS NULL)"
    t.index ["import_item_id"], name: "index_certificates_on_import_item_id"
    t.index ["verified_by_id"], name: "index_certificates_on_verified_by_id"
  end

  create_table "crew_members", force: :cascade do |t|
    t.string "first_name", null: false
    t.string "last_name", null: false
    t.string "preferred_name"
    t.string "name_aliases", default: [], null: false, array: true
    t.citext "email"
    t.string "phone"
    t.string "employer"
    t.bigint "crew_role_id"
    t.boolean "active", default: true, null: false
    t.boolean "expiry_emails_opt_in", default: false, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "possible_duplicate_of_id"
    t.index "lower((((first_name)::text || ' '::text) || (last_name)::text)) gin_trgm_ops", name: "index_crew_members_on_full_name_trgm", using: :gin
    t.index ["crew_role_id"], name: "index_crew_members_on_crew_role_id"
    t.index ["possible_duplicate_of_id"], name: "index_crew_members_on_possible_duplicate_of_id"
  end

  create_table "crew_roles", force: :cascade do |t|
    t.citext "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_crew_roles_on_name", unique: true
  end

  create_table "email_send_days", force: :cascade do |t|
    t.date "day", null: false
    t.integer "sent_count", default: 0, null: false
    t.integer "deferred_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_email_send_days_on_day", unique: true
  end

  create_table "expiry_notifications", force: :cascade do |t|
    t.bigint "certificate_id", null: false
    t.integer "threshold", null: false
    t.citext "recipient_email", null: false
    t.datetime "sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["certificate_id", "threshold", "recipient_email"], name: "index_expiry_notifications_uniqueness", unique: true
  end

  create_table "import_batches", force: :cascade do |t|
    t.bigint "uploaded_by_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "files_count", default: 0, null: false
    t.integer "items_count", default: 0, null: false
    t.integer "accepted_count", default: 0, null: false
    t.integer "review_count", default: 0, null: false
    t.integer "error_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "error_message"
    t.datetime "summary_sent_at"
    t.index ["status"], name: "index_import_batches_on_status"
    t.index ["uploaded_by_id"], name: "index_import_batches_on_uploaded_by_id"
  end

  create_table "import_items", force: :cascade do |t|
    t.bigint "import_batch_id", null: false
    t.string "original_filename"
    t.string "page_range"
    t.string "sha256"
    t.integer "status", default: 0, null: false
    t.text "extracted_text"
    t.jsonb "extraction"
    t.decimal "confidence", precision: 3, scale: 2
    t.string "holder_name_raw"
    t.string "certificate_name_raw"
    t.bigint "matched_crew_member_id"
    t.bigint "matched_certificate_type_id"
    t.date "proposed_completed_on"
    t.date "proposed_expires_on"
    t.string "proposed_certificate_number"
    t.string "provider"
    t.integer "ai_units_used"
    t.bigint "certificate_id"
    t.bigint "reviewed_by_id"
    t.datetime "reviewed_at"
    t.text "error_message"
    t.bigint "duplicate_of_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "person_match", default: 0, null: false
    t.integer "type_match", default: 0, null: false
    t.jsonb "person_suggestions", default: [], null: false
    t.jsonb "type_suggestions", default: [], null: false
    t.string "issuer_raw"
    t.integer "proposed_expires_on_source"
    t.bigint "source_item_id"
    t.string "rejection_reason"
    t.datetime "skipped_at"
    t.datetime "next_attempt_at"
    t.integer "attempts", default: 0, null: false
    t.bigint "matched_certificate_issuer_id"
    t.integer "issuer_match", default: 0, null: false
    t.jsonb "issuer_suggestions", default: [], null: false
    t.text "proposed_verification_code"
    t.text "proposed_verification_url"
    t.text "barcodes"
    t.integer "authenticity_status", default: 0, null: false
    t.datetime "authenticity_checked_at"
    t.bigint "authenticity_checked_by_id"
    t.string "authenticity_method"
    t.text "authenticity_note"
    t.jsonb "authenticity_details", default: {}, null: false
    t.integer "unread_qr_pages", default: [], null: false, array: true
    t.integer "ocr_pages", default: [], null: false, array: true
    t.jsonb "quality_flags", default: [], null: false
    t.string "content_digest"
    t.index ["authenticity_checked_by_id"], name: "index_import_items_on_authenticity_checked_by_id"
    t.index ["certificate_id"], name: "index_import_items_on_certificate_id"
    t.index ["content_digest"], name: "index_import_items_on_content_digest"
    t.index ["duplicate_of_id"], name: "index_import_items_on_duplicate_of_id"
    t.index ["import_batch_id"], name: "index_import_items_on_import_batch_id"
    t.index ["matched_certificate_issuer_id"], name: "index_import_items_on_matched_certificate_issuer_id"
    t.index ["matched_certificate_type_id"], name: "index_import_items_on_matched_certificate_type_id"
    t.index ["matched_crew_member_id"], name: "index_import_items_on_matched_crew_member_id"
    t.index ["reviewed_by_id"], name: "index_import_items_on_reviewed_by_id"
    t.index ["sha256", "page_range"], name: "index_import_items_on_sha256_and_page_range"
    t.index ["source_item_id"], name: "index_import_items_on_source_item_id"
    t.index ["status"], name: "index_import_items_on_status"
  end

  create_table "packet_builds", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "built_by_id"
    t.datetime "built_at", null: false
    t.string "packet_filename", null: false
    t.integer "certificate_count", default: 0, null: false
    t.integer "file_count", default: 0, null: false
    t.integer "gap_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["built_by_id"], name: "index_packet_builds_on_built_by_id"
    t.index ["project_id", "built_at"], name: "index_packet_builds_on_project_id_and_built_at"
  end

  create_table "project_assignments", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "crew_member_id", null: false
    t.bigint "crew_role_id"
    t.date "starts_on"
    t.date "ends_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["crew_member_id"], name: "index_project_assignments_on_crew_member_id"
    t.index ["crew_role_id"], name: "index_project_assignments_on_crew_role_id"
    t.index ["project_id", "crew_member_id"], name: "index_project_assignments_on_project_id_and_crew_member_id", unique: true
  end

  create_table "project_requirements", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "certificate_type_id", null: false
    t.bigint "crew_role_id"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["certificate_type_id"], name: "index_project_requirements_on_certificate_type_id"
    t.index ["crew_role_id"], name: "index_project_requirements_on_crew_role_id"
    t.index ["project_id", "certificate_type_id", "crew_role_id"], name: "index_project_requirements_uniqueness", unique: true, nulls_not_distinct: true
  end

  create_table "projects", force: :cascade do |t|
    t.string "name", null: false
    t.string "code"
    t.string "client"
    t.string "location"
    t.date "starts_on"
    t.date "ends_on"
    t.integer "status", default: 1, null: false
    t.datetime "packet_built_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_projects_on_code", unique: true
    t.index ["status"], name: "index_projects_on_status"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.citext "email_address", null: false
    t.string "password_digest", null: false
    t.string "name"
    t.integer "role", default: 2, null: false
    t.boolean "receives_digest", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "certificates", "certificate_issuers"
  add_foreign_key "certificates", "certificate_types", on_delete: :restrict
  add_foreign_key "certificates", "crew_members", on_delete: :restrict
  add_foreign_key "certificates", "import_items", on_delete: :restrict
  add_foreign_key "certificates", "users", column: "authenticity_checked_by_id", on_delete: :nullify
  add_foreign_key "certificates", "users", column: "verified_by_id", on_delete: :restrict
  add_foreign_key "crew_members", "crew_members", column: "possible_duplicate_of_id", on_delete: :nullify
  add_foreign_key "crew_members", "crew_roles", on_delete: :restrict
  add_foreign_key "expiry_notifications", "certificates", on_delete: :cascade
  add_foreign_key "import_batches", "users", column: "uploaded_by_id", on_delete: :restrict
  add_foreign_key "import_items", "certificate_issuers", column: "matched_certificate_issuer_id"
  add_foreign_key "import_items", "certificate_types", column: "matched_certificate_type_id", on_delete: :restrict
  add_foreign_key "import_items", "certificates", on_delete: :restrict
  add_foreign_key "import_items", "crew_members", column: "matched_crew_member_id", on_delete: :restrict
  add_foreign_key "import_items", "import_batches", on_delete: :cascade
  add_foreign_key "import_items", "import_items", column: "duplicate_of_id", on_delete: :nullify
  add_foreign_key "import_items", "import_items", column: "source_item_id", on_delete: :cascade
  add_foreign_key "import_items", "users", column: "authenticity_checked_by_id", on_delete: :nullify
  add_foreign_key "import_items", "users", column: "reviewed_by_id", on_delete: :restrict
  add_foreign_key "packet_builds", "projects", on_delete: :cascade
  add_foreign_key "packet_builds", "users", column: "built_by_id", on_delete: :nullify
  add_foreign_key "project_assignments", "crew_members", on_delete: :restrict
  add_foreign_key "project_assignments", "crew_roles", on_delete: :restrict
  add_foreign_key "project_assignments", "projects", on_delete: :cascade
  add_foreign_key "project_requirements", "certificate_types", on_delete: :restrict
  add_foreign_key "project_requirements", "crew_roles", on_delete: :restrict
  add_foreign_key "project_requirements", "projects", on_delete: :cascade
  add_foreign_key "sessions", "users"
end
