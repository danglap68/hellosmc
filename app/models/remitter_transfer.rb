# A transfer photo a remitter ("người đi tiền") posts in a Telegram group with
# a transfer code in the caption ("TK01"). The code names the HKD + agent, the
# sender names the remitter, OCR reads only the amount. An approved transfer
# adds one row to the agent's block in the day's "thu chi" tab.
# It is not a Transaction: it never touches DS MB, MB or "Bill vô chủ".
class RemitterTransfer < ApplicationRecord
  has_paper_trail ignore: %i[updated_at lock_version]

  STATUSES = %w[processing needs_review approved rejected failed].freeze
  CODE_SOURCES = %w[caption image manual].freeze

  belongs_to :telegram_message
  belongs_to :bill_image, optional: true
  belongs_to :remitter, optional: true
  belongs_to :merchant, optional: true
  belongs_to :merchant_dealer, optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :telegram_message_id, uniqueness: true
  validates :transferred_at, presence: true
  validates :code_source, inclusion: { in: CODE_SOURCES }, allow_nil: true
  validates :amount_vnd, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  scope :recent_first, -> { order(transferred_at: :desc, id: :desc) }
  scope :pending_write, -> { approved.where(written_at: nil) }

  def marker
    "RT#{id}"
  end

  def written?
    written_at.present?
  end

  def reviewed_by_human?
    reviewed_by_id.present?
  end

  def dealer
    merchant_dealer&.dealer
  end

  def chat
    telegram_message.telegram_chat
  end

  # The photo to show (a duplicate upload points at the first copy).
  def display_image
    bill_image&.duplicate_of || bill_image
  end

  def caption
    telegram_message.effective_text
  end

  # When the bank slip says the money was sent (read by OCR). transferred_at
  # is when the photo was posted in the group. A Date when only the day was
  # read, nil when the slip shows no date.
  def slip_at
    document = display_image&.documents&.find { |doc| doc["document_type"] == "transfer" && doc["transaction_date"].present? }
    return unless document

    date = Date.iso8601(document["transaction_date"])
    return date if document["transaction_time"].blank?

    hour, minute, second = document["transaction_time"].split(":").map(&:to_i)
    Time.zone.local(date.year, date.month, date.day, hour, minute, second)
  rescue Date::Error, ArgumentError
    nil
  end

  # Approved by a person or automatically, with everything the sheet needs.
  def writable?
    approved? && amount_vnd.present? && merchant_dealer.present? && remitter.present?
  end
end
