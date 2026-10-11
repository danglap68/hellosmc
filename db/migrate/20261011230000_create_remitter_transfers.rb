class CreateRemitterTransfers < ActiveRecord::Migration[8.1]
  # A transfer photo sent by a remitter with a code in the caption ("TK01").
  # Not a transaction: it only feeds the daily "thu chi" tab of the Hello SMC sheet.
  def change
    create_table :remitter_transfers do |t|
      t.references :telegram_message, null: false, foreign_key: true, index: { unique: true }
      t.references :bill_image, foreign_key: true, index: { unique: true }
      # Null when the photo was recognised as a transfer but the sender is not a
      # known remitter yet: a person picks the remitter while reviewing.
      t.references :remitter, foreign_key: true
      t.references :merchant, foreign_key: true
      t.references :merchant_dealer, foreign_key: true
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.string :transfer_code
      t.string :code_source
      t.bigint :amount_vnd
      t.decimal :amount_confidence, precision: 5, scale: 4
      t.datetime :transferred_at, null: false
      t.string :status, null: false, default: "processing"
      t.string :review_reasons, array: true, null: false, default: []
      t.datetime :reviewed_at
      t.string :rd_sheet
      t.integer :rd_row
      t.string :rd_cell
      t.datetime :written_at
      t.jsonb :metadata, null: false, default: {}
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :remitter_transfers, :status
    add_index :remitter_transfers, %i[remitter_id transfer_code amount_vnd], name: "index_remitter_transfers_on_duplicate_scope"
    add_check_constraint :remitter_transfers,
                         "status IN ('processing', 'needs_review', 'approved', 'rejected', 'failed')",
                         name: "remitter_transfers_status_check"
    add_check_constraint :remitter_transfers, "amount_vnd IS NULL OR amount_vnd > 0", name: "remitter_transfers_amount_positive"
  end
end
