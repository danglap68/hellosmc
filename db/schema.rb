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

ActiveRecord::Schema[8.1].define(version: 2026_10_08_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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

  create_table "app_secrets", force: :cascade do |t|
    t.string "key", null: false
    t.text "value", null: false
    t.bigint "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_app_secrets_on_key", unique: true
    t.index ["updated_by_id"], name: "index_app_secrets_on_updated_by_id"
  end

  create_table "app_settings", force: :cascade do |t|
    t.string "key", null: false
    t.text "value", null: false
    t.bigint "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_app_settings_on_key", unique: true
    t.index ["updated_by_id"], name: "index_app_settings_on_updated_by_id"
  end

  create_table "audit_logs", force: :cascade do |t|
    t.string "actor_type", null: false
    t.bigint "actor_id"
    t.string "action", null: false
    t.string "auditable_type"
    t.bigint "auditable_id"
    t.jsonb "before_data"
    t.jsonb "after_data"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["action"], name: "index_audit_logs_on_action"
    t.index ["actor_type", "actor_id"], name: "index_audit_logs_on_actor_type_and_actor_id"
    t.index ["auditable_type", "auditable_id"], name: "index_audit_logs_on_auditable_type_and_auditable_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
  end

  create_table "bill_images", force: :cascade do |t|
    t.bigint "telegram_message_id"
    t.string "source", default: "telegram", null: false
    t.bigint "uploaded_by_id"
    t.string "telegram_file_id"
    t.string "telegram_file_unique_id"
    t.bigint "duplicate_of_id"
    t.string "sha256"
    t.string "mime_type"
    t.bigint "file_size"
    t.integer "width"
    t.integer "height"
    t.string "ocr_status", default: "pending", null: false
    t.string "ocr_provider"
    t.string "ocr_model"
    t.decimal "ocr_confidence", precision: 5, scale: 4
    t.integer "ocr_attempts", default: 0, null: false
    t.datetime "analyzed_at"
    t.jsonb "raw_extraction"
    t.jsonb "normalized_extraction"
    t.text "processing_error"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["duplicate_of_id"], name: "index_bill_images_on_duplicate_of_id"
    t.index ["ocr_status"], name: "index_bill_images_on_ocr_status"
    t.index ["sha256"], name: "index_bill_images_on_sha256"
    t.index ["telegram_file_unique_id"], name: "index_bill_images_on_telegram_file_unique_id", unique: true, where: "(telegram_file_unique_id IS NOT NULL)"
    t.index ["telegram_message_id"], name: "index_bill_images_on_telegram_message_id"
    t.index ["uploaded_by_id"], name: "index_bill_images_on_uploaded_by_id"
    t.check_constraint "ocr_status::text = ANY (ARRAY['pending'::character varying::text, 'processing'::character varying::text, 'completed'::character varying::text, 'needs_review'::character varying::text, 'failed'::character varying::text, 'duplicate'::character varying::text])", name: "bill_images_ocr_status_check"
    t.check_constraint "source::text = ANY (ARRAY['telegram'::character varying::text, 'manual_upload'::character varying::text])", name: "bill_images_source_check"
  end

  create_table "card_types", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.string "aliases", default: [], null: false, array: true
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_card_types_on_key", unique: true
  end

  create_table "dealers", force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.boolean "active", default: true, null: false
    t.bigint "default_card_type_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_dealers_on_code", unique: true
    t.index ["default_card_type_id"], name: "index_dealers_on_default_card_type_id"
  end

  create_table "excel_exports", force: :cascade do |t|
    t.date "export_date", null: false
    t.date "end_date", null: false
    t.string "status", default: "pending", null: false
    t.integer "transaction_count", default: 0, null: false
    t.string "storage_key"
    t.bigint "generated_by_id"
    t.datetime "generated_at"
    t.text "error_message"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "layout", default: "legacy", null: false
    t.index ["export_date"], name: "index_excel_exports_on_export_date"
    t.index ["generated_by_id"], name: "index_excel_exports_on_generated_by_id"
    t.check_constraint "end_date >= export_date", name: "excel_exports_date_range"
    t.check_constraint "layout::text = ANY (ARRAY['legacy'::character varying::text, 'ket_toan_phi_goc'::character varying::text])", name: "excel_exports_layout_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'processing'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "excel_exports_status_check"
  end

  create_table "fee_rule_card_types", force: :cascade do |t|
    t.bigint "fee_rule_id", null: false
    t.bigint "card_type_id", null: false
    t.index ["card_type_id"], name: "index_fee_rule_card_types_on_card_type_id"
    t.index ["fee_rule_id", "card_type_id"], name: "index_fee_rule_card_types_on_fee_rule_id_and_card_type_id", unique: true
    t.index ["fee_rule_id"], name: "index_fee_rule_card_types_on_fee_rule_id"
  end

  create_table "fee_rule_merchants", force: :cascade do |t|
    t.bigint "fee_rule_id", null: false
    t.bigint "merchant_id", null: false
    t.index ["fee_rule_id", "merchant_id"], name: "index_fee_rule_merchants_on_fee_rule_id_and_merchant_id", unique: true
    t.index ["fee_rule_id"], name: "index_fee_rule_merchants_on_fee_rule_id"
    t.index ["merchant_id"], name: "index_fee_rule_merchants_on_merchant_id"
  end

  create_table "fee_rules", force: :cascade do |t|
    t.bigint "dealer_id"
    t.decimal "base_fee_rate", precision: 10, scale: 6, null: false
    t.decimal "dealer_rate", precision: 10, scale: 6
    t.datetime "effective_from", null: false
    t.datetime "effective_until"
    t.integer "priority", default: 100, null: false
    t.boolean "active", default: true, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active", "dealer_id"], name: "index_fee_rules_on_targeting"
    t.index ["dealer_id"], name: "index_fee_rules_on_dealer_id"
    t.index ["effective_from", "effective_until"], name: "index_fee_rules_on_effective_from_and_effective_until"
    t.check_constraint "base_fee_rate >= 0::numeric AND base_fee_rate < 1::numeric", name: "fee_rules_base_fee_rate_range"
    t.check_constraint "dealer_rate IS NULL OR dealer_rate >= 0::numeric AND dealer_rate < 1::numeric", name: "fee_rules_dealer_rate_range"
    t.check_constraint "effective_until IS NULL OR effective_until > effective_from", name: "fee_rules_effective_range"
  end

  create_table "merchant_aliases", force: :cascade do |t|
    t.bigint "merchant_id", null: false
    t.string "alias", null: false
    t.string "normalized_alias", null: false
    t.string "alias_type", default: "receipt_name", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alias_type", "normalized_alias"], name: "index_merchant_aliases_on_alias_type_and_normalized_alias"
    t.index ["merchant_id"], name: "index_merchant_aliases_on_merchant_id"
    t.index ["normalized_alias"], name: "index_merchant_aliases_on_normalized_alias"
    t.check_constraint "alias_type::text = ANY (ARRAY['receipt_name'::character varying::text, 'telegram_name'::character varying::text, 'merchant_id'::character varying::text, 'terminal_id'::character varying::text, 'terminal_name'::character varying::text, 'manual'::character varying::text])", name: "merchant_aliases_alias_type_check"
  end

  create_table "merchants", force: :cascade do |t|
    t.bigint "dealer_id"
    t.string "name", null: false
    t.string "normalized_name", null: false
    t.string "code", null: false
    t.boolean "active", default: true, null: false
    t.bigint "default_card_type_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_merchants_on_code", unique: true
    t.index ["dealer_id"], name: "index_merchants_on_dealer_id"
    t.index ["default_card_type_id"], name: "index_merchants_on_default_card_type_id"
    t.index ["normalized_name"], name: "index_merchants_on_normalized_name"
  end

  create_table "telegram_chats", force: :cascade do |t|
    t.bigint "telegram_chat_id", null: false
    t.string "name"
    t.string "chat_type"
    t.bigint "dealer_id"
    t.boolean "active", default: true, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dealer_id"], name: "index_telegram_chats_on_dealer_id"
    t.index ["telegram_chat_id"], name: "index_telegram_chats_on_telegram_chat_id", unique: true
  end

  create_table "telegram_messages", force: :cascade do |t|
    t.bigint "telegram_chat_id", null: false
    t.bigint "telegram_message_id", null: false
    t.bigint "telegram_update_id"
    t.bigint "telegram_sender_id"
    t.string "sender_name"
    t.string "media_group_id"
    t.text "message_text"
    t.datetime "sent_at"
    t.string "processing_status", default: "received", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["media_group_id"], name: "index_telegram_messages_on_media_group_id"
    t.index ["telegram_chat_id", "telegram_message_id"], name: "index_telegram_messages_on_chat_and_message", unique: true
    t.index ["telegram_chat_id"], name: "index_telegram_messages_on_telegram_chat_id"
    t.index ["telegram_update_id"], name: "index_telegram_messages_on_telegram_update_id"
  end

  create_table "transaction_reviews", force: :cascade do |t|
    t.bigint "transaction_id", null: false
    t.text "reason"
    t.string "reason_codes", default: [], null: false, array: true
    t.jsonb "original_values", default: {}, null: false
    t.jsonb "corrected_values", default: {}, null: false
    t.bigint "reviewed_by_id"
    t.datetime "reviewed_at"
    t.string "status", default: "open", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reviewed_by_id"], name: "index_transaction_reviews_on_reviewed_by_id"
    t.index ["status"], name: "index_transaction_reviews_on_status"
    t.index ["transaction_id"], name: "index_transaction_reviews_on_transaction_id"
    t.check_constraint "status::text = ANY (ARRAY['open'::character varying::text, 'approved'::character varying::text, 'rejected'::character varying::text, 'held'::character varying::text, 'superseded'::character varying::text])", name: "transaction_reviews_status_check"
  end

  create_table "transactions", force: :cascade do |t|
    t.bigint "telegram_message_id"
    t.bigint "bill_image_id"
    t.integer "source_index", default: 0, null: false
    t.bigint "dealer_id"
    t.bigint "merchant_id"
    t.bigint "card_type_id"
    t.bigint "fee_rule_id"
    t.string "lot_number"
    t.datetime "transaction_at"
    t.bigint "transaction_amount_vnd"
    t.decimal "applied_base_fee_rate", precision: 10, scale: 6
    t.bigint "amount_after_base_fee_vnd"
    t.decimal "applied_dealer_rate", precision: 10, scale: 6
    t.bigint "dealer_amount_vnd"
    t.bigint "profit_amount_vnd"
    t.string "status", default: "pending", null: false
    t.decimal "confidence_score", precision: 5, scale: 4
    t.jsonb "source_data", default: {}, null: false
    t.jsonb "calculation_data", default: {}, null: false
    t.bigint "approved_by_id"
    t.datetime "approved_at"
    t.datetime "exported_at"
    t.bigint "excel_export_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.index ["approved_by_id"], name: "index_transactions_on_approved_by_id"
    t.index ["bill_image_id", "source_index"], name: "index_transactions_on_bill_image_and_source_index", unique: true, where: "(bill_image_id IS NOT NULL)"
    t.index ["bill_image_id"], name: "index_transactions_on_bill_image_id"
    t.index ["card_type_id"], name: "index_transactions_on_card_type_id"
    t.index ["dealer_id"], name: "index_transactions_on_dealer_id"
    t.index ["excel_export_id"], name: "index_transactions_on_excel_export_id"
    t.index ["fee_rule_id"], name: "index_transactions_on_fee_rule_id"
    t.index ["lot_number"], name: "index_transactions_on_lot_number"
    t.index ["merchant_id", "transaction_amount_vnd", "transaction_at"], name: "index_transactions_for_duplicate_detection"
    t.index ["merchant_id"], name: "index_transactions_on_merchant_id"
    t.index ["status"], name: "index_transactions_on_status"
    t.index ["telegram_message_id"], name: "index_transactions_on_telegram_message_id"
    t.index ["transaction_at"], name: "index_transactions_on_transaction_at"
    t.check_constraint "(status::text <> ALL (ARRAY['approved'::character varying::text, 'exported'::character varying::text])) OR dealer_id IS NOT NULL AND merchant_id IS NOT NULL AND card_type_id IS NOT NULL AND transaction_at IS NOT NULL AND transaction_amount_vnd IS NOT NULL AND applied_base_fee_rate IS NOT NULL AND amount_after_base_fee_vnd IS NOT NULL", name: "transactions_approved_complete"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'processing'::character varying::text, 'needs_review'::character varying::text, 'approved'::character varying::text, 'rejected'::character varying::text, 'hold'::character varying::text, 'exported'::character varying::text, 'failed'::character varying::text])", name: "transactions_status_check"
    t.check_constraint "transaction_amount_vnd IS NULL OR transaction_amount_vnd > 0", name: "transactions_amount_positive"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.integer "failed_attempts", default: 0, null: false
    t.string "unlock_token"
    t.datetime "locked_at"
    t.string "name"
    t.string "role", default: "viewer", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
    t.check_constraint "role::text = ANY (ARRAY['admin'::character varying::text, 'operator'::character varying::text, 'viewer'::character varying::text])", name: "users_role_check"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "app_secrets", "users", column: "updated_by_id"
  add_foreign_key "app_settings", "users", column: "updated_by_id"
  add_foreign_key "bill_images", "bill_images", column: "duplicate_of_id"
  add_foreign_key "bill_images", "telegram_messages"
  add_foreign_key "bill_images", "users", column: "uploaded_by_id"
  add_foreign_key "dealers", "card_types", column: "default_card_type_id"
  add_foreign_key "excel_exports", "users", column: "generated_by_id"
  add_foreign_key "fee_rule_card_types", "card_types"
  add_foreign_key "fee_rule_card_types", "fee_rules"
  add_foreign_key "fee_rule_merchants", "fee_rules"
  add_foreign_key "fee_rule_merchants", "merchants"
  add_foreign_key "fee_rules", "dealers"
  add_foreign_key "merchant_aliases", "merchants"
  add_foreign_key "merchants", "card_types", column: "default_card_type_id"
  add_foreign_key "merchants", "dealers"
  add_foreign_key "telegram_chats", "dealers"
  add_foreign_key "telegram_messages", "telegram_chats"
  add_foreign_key "transaction_reviews", "transactions"
  add_foreign_key "transaction_reviews", "users", column: "reviewed_by_id"
  add_foreign_key "transactions", "bill_images"
  add_foreign_key "transactions", "card_types"
  add_foreign_key "transactions", "dealers"
  add_foreign_key "transactions", "excel_exports"
  add_foreign_key "transactions", "fee_rules"
  add_foreign_key "transactions", "merchants"
  add_foreign_key "transactions", "telegram_messages"
  add_foreign_key "transactions", "users", column: "approved_by_id"
end
