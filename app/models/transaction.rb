class Transaction < ApplicationRecord
  STATUSES = %w[pending processing needs_review approved rejected hold exported failed].freeze

  # Explicit state machine. Anything not listed here is refused.
  TRANSITIONS = {
    "pending" => %w[processing],
    "processing" => %w[approved needs_review failed],
    "needs_review" => %w[approved rejected hold processing],
    "approved" => %w[exported hold],
    "hold" => %w[approved needs_review rejected processing],
    "exported" => %w[hold],
    "failed" => %w[processing needs_review],
    "rejected" => []
  }.freeze

  # Statuses whose rows must carry complete, calculated accounting values.
  FINALIZED_STATUSES = %w[approved exported].freeze
  EDITABLE_STATUSES = %w[needs_review hold failed].freeze
  REPROCESSABLE_STATUSES = %w[needs_review hold failed].freeze

  class InvalidTransition < StandardError; end

  belongs_to :telegram_message, optional: true
  belongs_to :bill_image, optional: true
  belongs_to :dealer, optional: true
  belongs_to :merchant, optional: true
  belongs_to :card_type, optional: true
  belongs_to :fee_rule, optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :excel_export, optional: true

  has_many :reviews, class_name: "TransactionReview", foreign_key: :transaction_id,
    inverse_of: :reviewed_transaction, dependent: :destroy
  has_many :audit_logs, as: :auditable, dependent: :restrict_with_error

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :transaction_amount_vnd, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :applied_base_fee_rate, numericality: { greater_than_or_equal_to: 0, less_than: 1 }, allow_nil: true
  validates :applied_card_base_fee_rate, numericality: { greater_than_or_equal_to: 0, less_than: 1 }, allow_nil: true
  validates :applied_dealer_rate, numericality: { greater_than_or_equal_to: 0, less_than: 1 }, allow_nil: true
  validates :source_index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  with_options if: :finalized? do
    validates :dealer, :merchant, :card_type, :transaction_at, :transaction_amount_vnd,
              :applied_base_fee_rate, :amount_after_base_fee_vnd, presence: true
  end

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :review_queue, -> { where(status: "needs_review") }
  scope :not_rejected, -> { where.not(status: "rejected") }
  scope :on_business_date, ->(date) {
    zone = Time.zone
    where(transaction_at: zone.local(date.year, date.month, date.day).all_day)
  }

  def self.allowed_transition?(from, to)
    TRANSITIONS.fetch(from.to_s, []).include?(to.to_s)
  end

  def can_transition_to?(new_status)
    self.class.allowed_transition?(status, new_status)
  end

  def transition_to!(new_status, **attributes)
    new_status = new_status.to_s
    unless can_transition_to?(new_status)
      raise InvalidTransition, "Cannot move transaction #{id} from #{status} to #{new_status}"
    end

    update!(attributes.merge(status: new_status))
  end

  def finalized?
    status.in?(FINALIZED_STATUSES)
  end

  def editable?
    status.in?(EDITABLE_STATUSES)
  end

  def reprocessable?
    status.in?(REPROCESSABLE_STATUSES) && bill_image.present? && bill_image.image.attached? && bill_image.ocr_runs_remaining?
  end

  def open_review
    reviews.detect(&:open?) || reviews.open.order(created_at: :desc).first
  end

  def extraction
    source_data.fetch("extraction", {})
  end

  def field_confidence(field)
    value = extraction.dig("confidence", field.to_s)
    value.nil? ? nil : BigDecimal(value.to_s)
  end

  def raw_merchant_name
    extraction["merchant_name"]
  end

  def review_reason_codes
    Array(source_data["review_reasons"])
  end

  # Snapshot used in audit logs: only business-relevant columns.
  def audit_snapshot
    attributes.slice(
      "status", "dealer_id", "merchant_id", "card_type_id", "fee_rule_id", "lot_number", "transaction_at",
      "transaction_amount_vnd", "applied_base_fee_rate", "amount_after_base_fee_vnd", "applied_dealer_rate",
      "dealer_amount_vnd", "profit_amount_vnd", "confidence_score", "approved_by_id", "approved_at", "exported_at"
    )
  end
end
