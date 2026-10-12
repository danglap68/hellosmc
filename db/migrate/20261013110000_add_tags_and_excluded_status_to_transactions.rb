class AddTagsAndExcludedStatusToTransactions < ActiveRecord::Migration[8.1]
  STATUSES = %w[pending processing needs_review approved rejected hold exported failed].freeze

  def up
    add_column :transactions, :tags, :string, array: true, null: false, default: []
    add_index :transactions, :tags, using: :gin
    replace_status_check(STATUSES + %w[excluded])
  end

  def down
    # A row left `excluded` would break the narrower check: it goes back to review.
    execute "UPDATE transactions SET status = 'needs_review' WHERE status = 'excluded'"
    replace_status_check(STATUSES)
    remove_index :transactions, :tags
    remove_column :transactions, :tags
  end

  private

  def replace_status_check(statuses)
    remove_check_constraint :transactions, name: "transactions_status_check"
    list = statuses.map { |status| "'#{status}'::character varying::text" }.join(", ")
    add_check_constraint :transactions, "status::text = ANY (ARRAY[#{list}])", name: "transactions_status_check"
  end
end
