class AddCardBaseFeeRateToFeeRules < ActiveRecord::Migration[8.1]
  def change
    add_column :fee_rules, :card_base_fee_rate, :decimal, precision: 10, scale: 6
    add_check_constraint :fee_rules,
      "card_base_fee_rate IS NULL OR (card_base_fee_rate >= 0 AND card_base_fee_rate < 1)",
      name: "fee_rules_card_base_fee_rate_range"
  end
end