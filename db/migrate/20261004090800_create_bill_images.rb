class CreateBillImages < ActiveRecord::Migration[8.1]
  def change
    create_table :bill_images do |t|
      t.references :telegram_message, foreign_key: true
      t.string :source, null: false, default: "telegram"
      t.references :uploaded_by, foreign_key: { to_table: :users }
      t.string :telegram_file_id
      t.string :telegram_file_unique_id
      t.references :duplicate_of, foreign_key: { to_table: :bill_images }

      t.string :sha256
      t.string :mime_type
      t.bigint :file_size
      t.integer :width
      t.integer :height

      t.string :ocr_status, null: false, default: "pending"
      t.string :ocr_provider
      t.string :ocr_model
      t.decimal :ocr_confidence, precision: 5, scale: 4
      t.integer :ocr_attempts, null: false, default: 0
      t.datetime :analyzed_at

      t.jsonb :raw_extraction
      t.jsonb :normalized_extraction
      t.text :processing_error
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
    add_index :bill_images, :sha256
    add_index :bill_images, :ocr_status
    add_index :bill_images, :telegram_file_unique_id, unique: true, where: "telegram_file_unique_id IS NOT NULL"
    add_check_constraint :bill_images,
      "ocr_status IN ('pending', 'processing', 'completed', 'needs_review', 'failed', 'duplicate')",
      name: "bill_images_ocr_status_check"
    add_check_constraint :bill_images, "source IN ('telegram', 'manual_upload')", name: "bill_images_source_check"
  end
end
