class CreateHelloSmcWorkbookTables < ActiveRecord::Migration[8.1]
  def change
    create_table :remitters do |t|
      t.string :name, null: false
      t.string :excel_key, null: false
      t.bigint :telegram_user_id
      t.string :telegram_username
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :remitters, :excel_key, unique: true
    add_index :remitters, :telegram_user_id, unique: true, where: "telegram_user_id IS NOT NULL"
    add_index :remitters, :telegram_username, unique: true, where: "telegram_username IS NOT NULL"

    create_table :merchant_dealers do |t|
      t.references :merchant, null: false, foreign_key: true
      t.references :dealer, null: false, foreign_key: true
      t.string :tid_key, null: false
      t.string :tid_label, null: false
      t.string :ds_sheet_anchor, null: false
      t.string :ds_header, null: false
      t.string :rd_agent_label, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :merchant_dealers, [ :merchant_id, :dealer_id, :tid_key ], unique: true, name: "index_merchant_dealers_on_trio"
    add_index :merchant_dealers, [ :merchant_id, :tid_key ], unique: true, where: "active = TRUE", name: "index_merchant_dealers_on_merchant_tid"

    create_table :workbook_entries do |t|
      t.references :transaction, null: false, foreign_key: true
      t.string :spreadsheet_id, null: false
      t.string :branch, null: false
      t.string :ds_sheet
      t.string :ds_cell
      t.string :rd_cell
      t.integer :mb_row
      t.integer :unidentified_row
      t.bigint :amount_vnd, null: false
      t.jsonb :payload, default: {}, null: false
      t.timestamps
    end
    add_index :workbook_entries, :transaction_id, unique: true, name: "index_workbook_entries_on_transaction_id_unique"

    add_reference :telegram_chats, :merchant, foreign_key: true
    add_column :telegram_messages, :telegram_username, :string
  end
end
