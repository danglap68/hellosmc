class TelegramChatMerchant < ApplicationRecord
  belongs_to :telegram_chat
  belongs_to :merchant

  validates :merchant_id, uniqueness: { scope: :telegram_chat_id }
end
