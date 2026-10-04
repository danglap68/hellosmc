class Dealer < ApplicationRecord
  belongs_to :default_card_type, class_name: "CardType", optional: true

  has_many :telegram_chats, dependent: :restrict_with_error
  has_many :merchants, dependent: :restrict_with_error
  has_many :fee_rules, dependent: :restrict_with_error
  has_many :transactions, dependent: :restrict_with_error

  before_validation { self.code = code.to_s.strip.upcase.presence }

  validates :name, presence: true, length: { maximum: 200 }
  validates :code, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 50 }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name) }

  def display_name
    name
  end
end
