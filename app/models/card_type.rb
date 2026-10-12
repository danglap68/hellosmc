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

  # A new card type gets its code from its name ("Thẻ Visa" -> "the_visa") and
  # goes last in the list; the code never changes afterwards (tags and rules use it).
  # "Thẻ Visa" -> "the_visa"; "the_visa_2" when taken (the code is not on the
  # form any more, so a clash must not block the client).
  def key_from_name
    base = VietnameseText.strip_diacritics(name.to_s).downcase.gsub(/[^a-z0-9]+/, "_").delete_prefix("_").delete_suffix("_")
    return if base.blank?

    taken = self.class.where("key = :base OR key LIKE :pattern", base: base, pattern: "#{base}\\_%").pluck(:key)
    return base unless taken.include?(base)

    (2..).each { |n| return "#{base}_#{n}" unless taken.include?("#{base}_#{n}") }
  end

  def normalize_key_and_aliases
    self.key = key.to_s.strip.downcase.presence || (new_record? ? key_from_name : nil)
    self.position = (self.class.maximum(:position) || 0) + 1 if new_record? && position.to_i.zero?
    self.aliases = Array(aliases).map { |token| VietnameseText.normalize(token) }.reject(&:blank?).uniq
  end
end
