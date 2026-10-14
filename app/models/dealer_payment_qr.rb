class DealerPaymentQr < ApplicationRecord
  belongs_to :recorded_transaction, class_name: "Transaction", foreign_key: :transaction_id,
             inverse_of: :dealer_payment_qr
  belongs_to :dealer
  belongs_to :merchant_dealer, optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true

  enum :status, %w[pending confirmed cancelled blocked].index_by(&:itself), validate: true
  validates :access_token, presence: true, uniqueness: true
  validates :transfer_amount_vnd, numericality: { only_integer: true, greater_than: 0, less_than: 10**13 }, allow_nil: true

  def source_chat
    recorded_transaction.telegram_message&.telegram_chat
  end

  def current?
    recorded_transaction.reload.approved? && PaymentQrs::Snapshot.call(recorded_transaction) == snapshot
  rescue PaymentQrs::Error
    false
  end

  def audit_snapshot
    attributes.except("access_token", "qr_payload", "created_at", "updated_at")
  end
end
