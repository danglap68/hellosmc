class BillImage < ApplicationRecord
  OCR_STATUSES = %w[pending processing completed needs_review failed duplicate].freeze
  SOURCES = %w[telegram manual_upload].freeze
  # Formats accepted by the vision providers.
  ALLOWED_MIME_TYPES = %w[image/jpeg image/png image/webp].freeze

  belongs_to :telegram_message, optional: true
  belongs_to :uploaded_by, class_name: "User", optional: true
  belongs_to :duplicate_of, class_name: "BillImage", optional: true

  has_many :transactions, dependent: :restrict_with_error
  has_one_attached :image

  enum :ocr_status, OCR_STATUSES.index_by(&:itself), prefix: :ocr, validate: true
  enum :source, SOURCES.index_by(&:itself), validate: true

  validate :image_type_and_size

  scope :analyzable, -> { where(duplicate_of_id: nil).where.not(ocr_status: "duplicate") }

  def documents
    Array(normalized_extraction&.dig("documents"))
  end

  def telegram_chat
    telegram_message&.telegram_chat
  end

  # Manual uploads carry the dealer and card type chosen by the uploader.
  def manual_dealer_id
    metadata["dealer_id"]
  end

  def manual_card_type_key
    metadata["card_type_key"]
  end

  def message_text
    telegram_message&.effective_text
  end

  private

  def image_type_and_size
    return unless image.attached?

    unless image.blob.content_type.in?(ALLOWED_MIME_TYPES)
      errors.add(:image, :invalid_content_type)
    end
    if image.blob.byte_size > AppConfig.max_bill_image_bytes
      errors.add(:image, :too_large)
    end
  end
end
