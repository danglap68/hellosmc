class AddAppliedCardBaseFeeRateToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :applied_card_base_fee_rate, :decimal, precision: 10, scale: 6
    add_check_constraint :transactions,
      "applied_card_base_fee_rate IS NULL OR (applied_card_base_fee_rate >= 0 AND applied_card_base_fee_rate < 1)",
      name: "transactions_applied_card_base_fee_rate_range"
  end
end