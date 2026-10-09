class CardType < ApplicationRecord
  DEFAULT_KEY = "normal".freeze

  has_many :fee_rule_card_types, dependent: :restrict_with_error
  has_many :fee_rules, through: :fee_rule_card_types
  has_many :transactions, dependent: :restrict_with_error

  before_validation :normalize_key_and_aliases

  validates :key, presence: true, uniqueness: true, format: { with: /\A[a-z0-9_]+\z/ }
  validates :name, presence: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :key) }

  def self.default
    find_by(key: DEFAULT_KEY)
  end

  # Tokens the Telegram message parser looks for; the key itself always counts.
  def match_tokens
    ([ key ] + aliases).map { |token| VietnameseText.normalize(token) }.reject(&:blank?).uniq
  end

  def aliases_text
    aliases.join(", ")
  end

  def aliases_text=(value)
    self.aliases = value.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  private

  def normalize_key_and_aliases
    self.key = key.to_s.strip.downcase.presence
    self.aliases = Array(aliases).map { |token| VietnameseText.normalize(token) }.reject(&:blank?).uniq
  end
end
