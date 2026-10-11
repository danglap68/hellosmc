class AllowManyCardTypesOnFeeRules < ActiveRecord::Migration[8.1]
  def up
    create_table :fee_rule_card_types do |t|
      t.references :fee_rule, null: false, foreign_key: true
      t.references :card_type, null: false, foreign_key: true
      t.index [ :fee_rule_id, :card_type_id ], unique: true
    end

    execute <<~SQL.squish
      INSERT INTO fee_rule_card_types (fee_rule_id, card_type_id)
      SELECT id, card_type_id FROM fee_rules WHERE card_type_id IS NOT NULL
    SQL

    remove_index :fee_rules, name: "index_fee_rules_on_targeting"
    remove_reference :fee_rules, :card_type, foreign_key: true, index: true
    add_index :fee_rules, [ :active, :dealer_id ], name: "index_fee_rules_on_targeting"
  end

  def down
    add_reference :fee_rules, :card_type, foreign_key: true, index: true
    execute <<~SQL.squish
      UPDATE fee_rules
      SET card_type_id = picked.card_type_id
      FROM (
        SELECT DISTINCT ON (fee_rule_id) fee_rule_id, card_type_id
        FROM fee_rule_card_types
        ORDER BY fee_rule_id, card_type_id
      ) picked
      WHERE fee_rules.id = picked.fee_rule_id
    SQL
    remove_index :fee_rules, name: "index_fee_rules_on_targeting"
    add_index :fee_rules, [ :active, :dealer_id, :card_type_id ], name: "index_fee_rules_on_targeting"
    drop_table :fee_rule_card_types
  end
end
