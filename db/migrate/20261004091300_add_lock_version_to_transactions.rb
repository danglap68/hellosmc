# Optimistic locking: a reviewer working from a stale copy cannot overwrite
# a decision taken meanwhile by someone else.
class AddLockVersionToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :lock_version, :integer, null: false, default: 0
  end
end
