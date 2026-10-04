class TransactionReview < ApplicationRecord
  STATUSES = %w[open approved rejected held superseded].freeze

  # `transaction` would clash with ActiveRecord#transaction, hence the explicit name.
  belongs_to :reviewed_transaction, class_name: "Transaction", foreign_key: :transaction_id, inverse_of: :reviews
  belongs_to :reviewed_by, class_name: "User", optional: true

  enum :status, STATUSES.index_by(&:itself), validate: true

  scope :recent_first, -> { order(created_at: :desc) }
end
