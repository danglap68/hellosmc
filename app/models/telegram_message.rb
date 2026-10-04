class TelegramMessage < ApplicationRecord
  PROCESSING_STATUSES = %w[received ignored queued processed failed].freeze

  belongs_to :telegram_chat
  has_many :bill_images, dependent: :restrict_with_error
  has_many :transactions, dependent: :restrict_with_error

  enum :processing_status, PROCESSING_STATUSES.index_by(&:itself), prefix: :processing, validate: true

  validates :telegram_message_id, presence: true, uniqueness: { scope: :telegram_chat_id }

  scope :with_image, -> {
    where(<<~SQL.squish)
      COALESCE(raw_payload -> 'message', raw_payload -> 'channel_post') ? 'photo'
      OR COALESCE(raw_payload -> 'message', raw_payload -> 'channel_post') -> 'document' ->> 'mime_type' LIKE 'image/%'
    SQL
  }
  # Images received while the chat was inactive: stored, never downloaded.
  scope :stored_unprocessed_images, -> { processing_ignored.with_image.where.missing(:bill_images) }

  # The message object inside the stored update payload.
  def raw_message
    keys = Telegram::MessageParser::MESSAGE_KEYS + Telegram::MessageParser::EDIT_KEYS
    raw_payload.values_at(*keys).compact.first || {}
  end

  # Transactions whose card type may depend on this message's text
  # (the message itself and, for albums, every photo of the album).
  def related_transactions
    message_ids =
      if media_group_id.present?
        TelegramMessage.where(telegram_chat_id: telegram_chat_id, media_group_id: media_group_id).select(:id)
      else
        [ id ]
      end
    Transaction.where(telegram_message_id: message_ids)
  end

  # Telegram sends an album as separate messages sharing a media_group_id;
  # only the first one carries the caption. Fall back to a sibling's caption.
  def effective_text
    return message_text if message_text.present?
    return nil if media_group_id.blank?

    TelegramMessage.where(telegram_chat_id: telegram_chat_id, media_group_id: media_group_id)
      .where.not(message_text: [ nil, "" ])
      .order(:telegram_message_id)
      .pick(:message_text)
  end
end
