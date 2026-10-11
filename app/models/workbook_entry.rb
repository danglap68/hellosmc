class WorkbookEntry < ApplicationRecord
  BRANCHES = %w[identified unidentified].freeze

  belongs_to :recorded_transaction, class_name: "Transaction", foreign_key: :transaction_id, inverse_of: :workbook_entry

  validates :spreadsheet_id, :amount_vnd, presence: true
  validates :branch, inclusion: { in: BRANCHES }
  validates :transaction_id, uniqueness: true
end
