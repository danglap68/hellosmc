class MerchantAlias < ApplicationRecord
  ALIAS_TYPES = %w[receipt_name telegram_name merchant_id terminal_id terminal_name manual].freeze
  # Identifier aliases are compared as compact alphanumerics (e.g. MID/TID printed on the receipt).
  IDENTIFIER_TYPES = %w[merchant_id terminal_id].freeze
  NAME_TYPES = (ALIAS_TYPES - IDENTIFIER_TYPES).freeze

  belongs_to :merchant

  enum :alias_type, ALIAS_TYPES.index_by(&:itself), validate: true

  before_validation :normalize_alias

  validates :alias, presence: true, length: { maximum: 255 }
  validates :normalized_alias, presence: true
  validate :normalized_alias_unique_among_active

  scope :active, -> { where(active: true) }
  scope :identifiers, -> { where(alias_type: IDENTIFIER_TYPES) }
  scope :names, -> { where(alias_type: NAME_TYPES) }

  def identifier?
    alias_type.in?(IDENTIFIER_TYPES)
  end

  def self.normalize_for(alias_type, value)
    if alias_type.to_s.in?(IDENTIFIER_TYPES)
      VietnameseText.normalize_identifier(value)
    else
      VietnameseText.normalize(value)
    end
  end

  private

  def normalize_alias
    self.alias = self.alias.to_s.strip
    self.normalized_alias = self.class.normalize_for(alias_type, self.alias).presence
  end

  # The same alias pointing at two merchants would make resolution ambiguous.
  def normalized_alias_unique_among_active
    return unless active? && normalized_alias.present?

    clash = MerchantAlias.active
      .where(alias_type: identifier? ? IDENTIFIER_TYPES : NAME_TYPES, normalized_alias: normalized_alias)
      .where.not(id: id)
      .where.not(merchant_id: merchant_id)
      .includes(:merchant)
      .first
    return unless clash

    errors.add(:alias, :taken_by_merchant, merchant: clash.merchant.name)
  end
end
