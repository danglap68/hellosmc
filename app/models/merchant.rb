class Merchant < ApplicationRecord
  belongs_to :dealer, optional: true
  belongs_to :default_card_type, class_name: "CardType", optional: true

  has_many :merchant_aliases, dependent: :destroy
  has_many :fee_rule_merchants, dependent: :restrict_with_error
  has_many :fee_rules, through: :fee_rule_merchants
  has_many :transactions, dependent: :restrict_with_error

  before_validation :normalize_fields

  validates :name, presence: true, length: { maximum: 255 }
  validates :normalized_name, presence: true
  validates :code, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 50 }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name) }

  def display_name
    name
  end

  def core_name
    VietnameseText.core_name(name)
  end

  private

  def normalize_fields
    self.code = code.to_s.strip.upcase.presence
    self.normalized_name = VietnameseText.normalize(name)
  end
end
