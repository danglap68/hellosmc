# A Telegram media group (album): one dealer sends several "bill con"
# (child_receipt) photos and one bank-transfer photo together. The album groups
# the messages, OCRs each image, builds one transaction per child bill, then
# reconciles sum(child bills) against the transfer amount.
class BillAlbum < ApplicationRecord
  STATUSES = %w[collecting processing reconciled needs_review skipped failed].freeze
  RECONCILIATION_STATUSES = %w[matched mismatched multiple_transfers missing_bills no_transfer
                               transfer_duplicate incomplete].freeze
  TERMINAL_STATUSES = %w[reconciled needs_review skipped failed].freeze

  belongs_to :telegram_chat
  belongs_to :transfer_bill_image, class_name: "BillImage", optional: true
  has_many :bill_images, dependent: :nullify
  has_many :transactions, through: :bill_images

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :media_group_id, presence: true, uniqueness: { scope: :telegram_chat_id }
  validates :reconciliation_status, inclusion: { in: RECONCILIATION_STATUSES }, allow_nil: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def messages
    telegram_chat.telegram_messages.where(media_group_id: media_group_id)
  end

  # Messages that are still expected to produce an image (download in flight).
  # Failed/ignored messages will never get one, so they are not waited on.
  def messages_without_images?
    messages.where(processing_status: %w[received queued]).where.missing(:bill_images).exists?
  end

  def images_pending_ocr?
    bill_images.where(ocr_status: %w[pending processing]).exists?
  end

  def any_ocr_failed?
    bill_images.analyzable.where(ocr_status: "failed").exists?
  end
end
