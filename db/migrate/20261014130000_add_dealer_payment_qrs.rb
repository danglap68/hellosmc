class AddDealerPaymentQrs < ActiveRecord::Migration[8.1]
  def change
    add_column :dealers, :bank_bin, :string
    add_column :dealers, :bank_account_number, :string
    add_column :dealers, :bank_account_name, :string
    add_column :dealers, :auto_payment_qr, :boolean, default: false, null: false
    add_column :telegram_chats, :payment_qr_confirmer_ids, :bigint, array: true, default: [], null: false

    create_table :dealer_payment_qrs do |t|
      t.references :transaction, null: false, foreign_key: true, index: { unique: true }
      t.references :dealer, null: false, foreign_key: true
      t.references :merchant_dealer, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.jsonb :snapshot, null: false, default: {}
      t.string :issue
      t.string :access_token, null: false
      t.integer :lock_version, null: false, default: 0
      t.bigint :transfer_amount_vnd
      t.text :qr_payload
      t.datetime :confirmed_at
      t.references :confirmed_by, foreign_key: { to_table: :users }
      t.bigint :confirmed_by_telegram_id
      t.string :summary_delivery, null: false, default: "idle"
      t.string :qr_delivery, null: false, default: "idle"
      t.bigint :summary_message_id
      t.bigint :qr_message_id
      t.string :delivery_error
      t.timestamps
    end
    add_index :dealer_payment_qrs, :status
    add_index :dealer_payment_qrs, :access_token, unique: true
  end
end
