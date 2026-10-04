class CreateFeeRules < ActiveRecord::Migration[8.1]
  def change
    create_table :fee_rules do |t|
      t.references :merchant, foreign_key: true
      t.references :dealer, foreign_key: true
      t.references :card_type, foreign_key: true
      t.decimal :base_fee_rate, precision: 10, scale: 6, null: false
      t.decimal :dealer_rate, precision: 10, scale: 6
      t.datetime :effective_from, null: false
      t.datetime :effective_until
      t.integer :priority, null: false, default: 100
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :fee_rules, [ :effective_from, :effective_until ]
    add_index :fee_rules, [ :active, :merchant_id, :dealer_id, :card_type_id ], name: "index_fee_rules_on_targeting"
    add_check_constraint :fee_rules, "base_fee_rate >= 0 AND base_fee_rate < 1", name: "fee_rules_base_fee_rate_range"
    add_check_constraint :fee_rules, "dealer_rate IS NULL OR (dealer_rate >= 0 AND dealer_rate < 1)", name: "fee_rules_dealer_rate_range"
    add_check_constraint :fee_rules, "effective_until IS NULL OR effective_until > effective_from", name: "fee_rules_effective_range"
  end
end
