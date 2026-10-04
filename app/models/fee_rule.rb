class FeeRule < ApplicationRecord
  # Ordered from most to least specific. The resolver picks the first level
  # with matching rules; inside a level the lowest priority number wins.
  SPECIFICITY_LEVELS = %w[merchant_card_type dealer_card_type merchant dealer card_type system_default].freeze

  belongs_to :merchant, optional: true
  belongs_to :dealer, optional: true
  belongs_to :card_type, optional: true

  has_many :transactions, dependent: :restrict_with_error

  validates :base_fee_rate, presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than: 1 }
  validates :dealer_rate, numericality: { greater_than_or_equal_to: 0, less_than: 1 }, allow_nil: true
  validates :effective_from, presence: true
  validates :priority, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :effective_range_valid
  validate :merchant_belongs_to_dealer
  validate :no_overlapping_rule_with_same_precedence

  scope :active, -> { where(active: true) }
  scope :effective_at, ->(time) {
    where("fee_rules.effective_from <= ?", time)
      .where("fee_rules.effective_until IS NULL OR fee_rules.effective_until > ?", time)
  }
  scope :ordered, -> { order(:priority, effective_from: :desc, id: :desc) }

  def specificity_level
    if merchant_id && card_type_id then "merchant_card_type"
    elsif dealer_id && card_type_id && !merchant_id then "dealer_card_type"
    elsif merchant_id then "merchant"
    elsif dealer_id then "dealer"
    elsif card_type_id then "card_type"
    else "system_default"
    end
  end

  def specificity_rank
    SPECIFICITY_LEVELS.index(specificity_level)
  end

  def system_default?
    merchant_id.nil? && dealer_id.nil? && card_type_id.nil?
  end

  def effective_at?(time)
    effective_from <= time && (effective_until.nil? || effective_until > time)
  end

  def note
    metadata["note"]
  end

  def note=(value)
    self.metadata = metadata.merge("note" => value.to_s.strip.presence).compact
  end

  # The admin UI edits percentages ("0,88") while the database stores rates (0.0088).
  def base_fee_percent
    @base_fee_percent || Percentage.rate_to_percent_string(base_fee_rate)
  end

  def base_fee_percent=(value)
    @base_fee_percent = value
    self.base_fee_rate = rate_or_raw(value)
  end

  def dealer_percent
    @dealer_percent || Percentage.rate_to_percent_string(dealer_rate)
  end

  def dealer_percent=(value)
    @dealer_percent = value
    self.dealer_rate = rate_or_raw(value)
  end

  def snapshot_attributes
    attributes.slice("id", "merchant_id", "dealer_id", "card_type_id", "base_fee_rate", "dealer_rate",
                     "effective_from", "effective_until", "priority").merge("specificity_level" => specificity_level)
  end

  private

  # Unparseable input is kept raw so the numericality validation reports it.
  def rate_or_raw(value)
    rate = Percentage.percent_to_rate(value)
    rate.nil? && value.present? ? value : rate
  end

  def effective_range_valid
    return if effective_from.blank? || effective_until.blank?
    return if effective_until > effective_from

    errors.add(:effective_until, :after_effective_from)
  end

  def merchant_belongs_to_dealer
    return unless merchant && dealer && merchant.dealer_id.present?
    return if merchant.dealer_id == dealer_id

    errors.add(:merchant_id, :dealer_mismatch)
  end

  # Two active rules with the same targeting and priority whose validity
  # windows overlap would be ambiguous at resolution time; refuse to save them.
  def no_overlapping_rule_with_same_precedence
    return unless active? && effective_from.present? && priority.present?

    overlapping = FeeRule.active
      .where(merchant_id: merchant_id, dealer_id: dealer_id, card_type_id: card_type_id, priority: priority)
      .where.not(id: id)
      .where("effective_until IS NULL OR effective_until > ?", effective_from)
    overlapping = overlapping.where("effective_from < ?", effective_until) if effective_until.present?

    clash = overlapping.first
    errors.add(:base, :overlapping_rule, id: clash.id) if clash
  end
end
