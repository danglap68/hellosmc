# An album whose settlement bill printed everything is no longer reconciled
# against its child bills: it gets its own reconciliation status.
class AllowSettlementCompleteAlbumReconciliation < ActiveRecord::Migration[8.1]
  OLD = "'matched', 'mismatched', 'multiple_transfers', 'missing_bills', 'no_transfer', 'transfer_duplicate', 'incomplete'".freeze
  NEW = "#{OLD}, 'settlement_complete'".freeze

  def up
    replace_constraint(NEW)
  end

  def down
    execute "UPDATE bill_albums SET reconciliation_status = 'matched' WHERE reconciliation_status = 'settlement_complete'"
    replace_constraint(OLD)
  end

  private

  def replace_constraint(values)
    remove_check_constraint :bill_albums, name: "bill_albums_reconciliation_status_check"
    add_check_constraint :bill_albums, "reconciliation_status IS NULL OR reconciliation_status IN (#{values})",
                         name: "bill_albums_reconciliation_status_check"
  end
end
