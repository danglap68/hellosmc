class RemoveExportedStatusFromTransactions < ActiveRecord::Migration[8.1]
  STATUSES = %w[pending processing needs_review approved rejected hold failed excluded].freeze
  COMPLETE_COLUMNS = "dealer_id IS NOT NULL AND merchant_id IS NOT NULL AND card_type_id IS NOT NULL " \
                     "AND transaction_at IS NOT NULL AND transaction_amount_vnd IS NOT NULL " \
                     "AND applied_base_fee_rate IS NOT NULL AND amount_after_base_fee_vnd IS NOT NULL".freeze

  def up
    # The version row keeps the old status visible in the transaction's history.
    execute <<~SQL
      INSERT INTO versions (item_type, item_id, event, whodunnit, object, object_changes, created_at)
      SELECT 'Transaction', t.id, 'update', NULL, to_jsonb(t) - 'source_data',
             jsonb_build_object('status', jsonb_build_array('exported', 'approved')), now()
      FROM transactions t
      WHERE t.status = 'exported'
    SQL
    execute "UPDATE transactions SET status = 'approved', updated_at = now() WHERE status = 'exported'"

    replace_status_check(STATUSES)
    replace_complete_check(%w[approved])
  end

  def down
    replace_complete_check(%w[approved exported])
    replace_status_check(STATUSES.dup.insert(STATUSES.index("hold") + 1, "exported"))
    execute "UPDATE transactions SET status = 'exported' WHERE status = 'approved' AND exported_at IS NOT NULL"
  end

  private

  def replace_status_check(statuses)
    remove_check_constraint :transactions, name: "transactions_status_check"
    list = statuses.map { |status| "'#{status}'::character varying::text" }.join(", ")
    add_check_constraint :transactions, "status::text = ANY (ARRAY[#{list}])", name: "transactions_status_check"
  end

  def replace_complete_check(statuses)
    remove_check_constraint :transactions, name: "transactions_approved_complete"
    list = statuses.map { |status| "'#{status}'::character varying" }.join(", ")
    add_check_constraint :transactions, "(status::text <> ALL (ARRAY[#{list}]::text[])) OR #{COMPLETE_COLUMNS}",
      name: "transactions_approved_complete"
  end
end
