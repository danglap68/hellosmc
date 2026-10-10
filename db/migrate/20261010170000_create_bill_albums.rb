class CreateBillAlbums < ActiveRecord::Migration[8.1]
  def change
    create_table :bill_albums do |t|
      t.references :telegram_chat, null: false, foreign_key: true
      t.string :media_group_id, null: false
      t.string :status, null: false, default: "collecting"
      t.datetime :collect_until
      t.string :reconciliation_status
      t.references :transfer_bill_image, foreign_key: { to_table: :bill_images }
      t.bigint :transfer_amount_vnd
      t.bigint :child_total_vnd
      t.integer :child_count, null: false, default: 0
      t.integer :transfer_count, null: false, default: 0
      t.bigint :match_difference_vnd
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :bill_albums, [ :telegram_chat_id, :media_group_id ], unique: true, name: "index_bill_albums_on_chat_and_media_group"
    add_index :bill_albums, :status

    add_check_constraint :bill_albums,
      "status IN ('collecting', 'processing', 'reconciled', 'needs_review', 'skipped', 'failed')",
      name: "bill_albums_status_check"
    add_check_constraint :bill_albums,
      "reconciliation_status IS NULL OR reconciliation_status IN ('matched', 'mismatched', 'multiple_transfers', 'missing_bills', 'no_transfer', 'transfer_duplicate', 'incomplete')",
      name: "bill_albums_reconciliation_status_check"
  end
end
