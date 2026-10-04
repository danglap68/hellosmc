class CreateMerchantAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :merchant_aliases do |t|
      t.references :merchant, null: false, foreign_key: true
      t.string :alias, null: false
      t.string :normalized_alias, null: false
      t.string :alias_type, null: false, default: "receipt_name"
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :merchant_aliases, :normalized_alias
    add_index :merchant_aliases, [ :alias_type, :normalized_alias ]
    add_check_constraint :merchant_aliases,
      "alias_type IN ('receipt_name', 'telegram_name', 'merchant_id', 'terminal_id', 'terminal_name', 'manual')",
      name: "merchant_aliases_alias_type_check"
  end
end
