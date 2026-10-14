# A Telegram group the bot is in. Only whether it is active matters: the HKD
# and the agent of a bill are read from the bill itself (OCR merchant name,
# TID), never from the group or its name.
class TelegramChat < ApplicationRecord
  has_many :telegram_messages, dependent: :restrict_with_error

  validates :telegram_chat_id, presence: true, uniqueness: true, numericality: { only_integer: true }
  validates :name, length: { maximum: 255 }
  validate do
    if @invalid_payment_qr_confirmer_ids
      errors.add(:payment_qr_confirmer_ids_text, "chỉ nhận Telegram user ID là số nguyên dương, ngăn cách bằng dấu phẩy hoặc xuống dòng")
    end
  end

  def payment_qr_confirmer_ids_text
    payment_qr_confirmer_ids.join(", ")
  end

  def payment_qr_confirmer_ids_text=(value)
    parts = value.to_s.split(/[\s,;]+/).reject(&:blank?)
    @invalid_payment_qr_confirmer_ids = parts.any? { |part| !part.match?(/\A[1-9]\d{0,15}\z/) }
    self.payment_qr_confirmer_ids = parts.map(&:to_i).uniq unless @invalid_payment_qr_confirmer_ids
  end

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name, :telegram_chat_id) }

  def display_name
    name.presence || telegram_chat_id.to_s
  end
end
