class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |t|
      t.references :telegram_message, foreign_key: true
      t.references :bill_image, foreign_key: true
      # Position of the settlement inside the source image (one image may hold several settlements).
      t.integer :source_index, null: false, default: 0

      t.references :dealer, foreign_key: true
      t.references :merchant, foreign_key: true
      t.references :card_type, foreign_key: true
      t.references :fee_rule, foreign_key: true

      t.string :lot_number
      t.datetime :transaction_at

      # Money is stored as whole VND in bigint. Never float.
      t.bigint :transaction_amount_vnd

      # Rates applied at processing time are snapshotted; never recomputed from current rules.
      t.decimal :applied_base_fee_rate, precision: 10, scale: 6
      t.bigint :amount_after_base_fee_vnd

      t.decimal :applied_dealer_rate, precision: 10, scale: 6
      t.bigint :dealer_amount_vnd
      t.bigint :profit_amount_vnd

      t.string :status, null: false, default: "pending"
      t.decimal :confidence_score, precision: 5, scale: 4

      t.jsonb :source_data, null: false, default: {}
      t.jsonb :calculation_data, null: false, default: {}

      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at
      t.datetime :exported_at
      t.references :excel_export, foreign_key: true

      t.timestamps
    end

    add_index :transactions, [ :bill_image_id, :source_index ], unique: true, where: "bill_image_id IS NOT NULL",
      name: "index_transactions_on_bill_image_and_source_index"
    add_index :transactions, :status
    add_index :transactions, :transaction_at
    add_index :transactions, :lot_number
    add_index :transactions, [ :merchant_id, :transaction_amount_vnd, :transaction_at ], name: "index_transactions_for_duplicate_detection"

    add_check_constraint :transactions,
      "status IN ('pending', 'processing', 'needs_review', 'approved', 'rejected', 'hold', 'exported', 'failed')",
      name: "transactions_status_check"
    add_check_constraint :transactions, "transaction_amount_vnd IS NULL OR transaction_amount_vnd > 0",
      name: "transactions_amount_positive"
    add_check_constraint :transactions,
      "status NOT IN ('approved', 'exported') OR (dealer_id IS NOT NULL AND merchant_id IS NOT NULL AND card_type_id IS NOT NULL " \
      "AND transaction_at IS NOT NULL AND transaction_amount_vnd IS NOT NULL AND applied_base_fee_rate IS NOT NULL " \
      "AND amount_after_base_fee_vnd IS NOT NULL)",
      name: "transactions_approved_complete"
  end
end
