class TelegramChat < ApplicationRecord
  belongs_to :dealer, optional: true
  has_many :telegram_messages, dependent: :restrict_with_error

  validates :telegram_chat_id, presence: true, uniqueness: true, numericality: { only_integer: true }
  validates :name, length: { maximum: 255 }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name, :telegram_chat_id) }
  scope :unmapped, -> { where(dealer_id: nil) }

  def display_name
    name.presence || telegram_chat_id.to_s
  end
end
