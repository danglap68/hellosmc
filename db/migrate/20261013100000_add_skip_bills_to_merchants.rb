class AddSkipBillsToMerchants < ActiveRecord::Migration[8.1]
  def up
    add_column :merchants, :skip_bills, :boolean, null: false, default: false
    # HKD Thiên Kim uses another fee calculation: its bills are skipped.
    execute "UPDATE merchants SET skip_bills = TRUE WHERE normalized_name LIKE '%thien kim%'"
  end

  def down
    remove_column :merchants, :skip_bills
  end
end
