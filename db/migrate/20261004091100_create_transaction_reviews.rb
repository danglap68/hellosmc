class CreateTransactionReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :transaction_reviews do |t|
      t.references :transaction, null: false, foreign_key: true
      t.text :reason
      t.string :reason_codes, array: true, null: false, default: []
      t.jsonb :original_values, null: false, default: {}
      t.jsonb :corrected_values, null: false, default: {}
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.string :status, null: false, default: "open"
      t.text :note
      t.timestamps
    end
    add_index :transaction_reviews, :status
    add_check_constraint :transaction_reviews, "status IN ('open', 'approved', 'rejected', 'held', 'superseded')",
      name: "transaction_reviews_status_check"
  end
end
