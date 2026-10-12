# A Telegram group the bot is in. Only whether it is active matters: the HKD
# and the agent of a bill are read from the bill itself (OCR merchant name,
# TID), never from the group or its name.
class TelegramChat < ApplicationRecord
  has_many :telegram_messages, dependent: :restrict_with_error

  validates :telegram_chat_id, presence: true, uniqueness: true, numericality: { only_integer: true }
  validates :name, length: { maximum: 255 }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name, :telegram_chat_id) }

  def display_name
    name.presence || telegram_chat_id.to_s
  end
end
