class FeeRule < ApplicationRecord
  # Ordered from most to least specific. The resolver picks the first level
  # with matching rules; inside a level the lowest priority number wins.
  SPECIFICITY_LEVELS = %w[merchant_card_type dealer_card_type merchant dealer card_type system_default].freeze

  belongs_to :dealer, optional: true

  has_many :fee_rule_merchants, dependent: :destroy
  has_many :merchants, through: :fee_rule_merchants
  has_many :fee_rule_card_types, dependent: :destroy
  has_many :card_types, through: :fee_rule_card_types
  has_many :transactions, dependent: :restrict_with_error

  validates :base_fee_rate, presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than: 1 }
  validates :dealer_rate, numericality: { greater_than_or_equal_to: 0, less_than: 1 }, allow_nil: true
  validates :card_base_fee_rate, numericality: { greater_than_or_equal_to: 0, less_than: 1 }, allow_nil: true
  validates :effective_from, presence: true
  validates :priority, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :effective_range_valid
  validate :merchant_belongs_to_dealer
  validate :no_overlapping_rule_with_same_precedence
  before_validation :clear_card_base_fee_without_card_types

  scope :active, -> { where(active: true) }
  scope :effective_at, ->(time) {
    where("fee_rules.effective_from <= ?", time)
      .where("fee_rules.effective_until IS NULL OR fee_rules.effective_until > ?", time)
  }
  scope :ordered, -> { order(:priority, effective_from: :desc, id: :desc) }
  # An empty join means every value of that dimension. A given id also matches rules that list it.
  COVERING_JOINS = { fee_rule_merchants: "merchant_id", fee_rule_card_types: "card_type_id" }.freeze

  scope :covering_merchant, ->(merchant_id) { where(FeeRule.covering_sql(:fee_rule_merchants, merchant_id)) }
  scope :assigned_to_merchant, ->(merchant_id) {
    where(id: FeeRuleMerchant.where(merchant_id: merchant_id).select(:fee_rule_id))
  }
  scope :covering_card_type, ->(card_type_id) { where(FeeRule.covering_sql(:fee_rule_card_types, card_type_id)) }
  scope :assigned_to_card_type, ->(card_type_id) {
    where(id: FeeRuleCardType.where(card_type_id: card_type_id).select(:fee_rule_id))
  }

  def merchant_ids=(ids)
    super(Array(ids).compact_blank.uniq)
  end

  def card_type_ids=(ids)
    super(Array(ids).compact_blank.uniq)
  end

  def specificity_level
    if targets_merchants? && targets_card_types? then "merchant_card_type"
    elsif dealer_id && targets_card_types? && !targets_merchants? then "dealer_card_type"
    elsif targets_merchants? then "merchant"
    elsif dealer_id then "dealer"
    elsif targets_card_types? then "card_type"
    else "system_default"
    end
  end

  def specificity_rank
    SPECIFICITY_LEVELS.index(specificity_level)
  end

  def system_default?
    !targets_merchants? && dealer_id.nil? && !targets_card_types?
  end

  def merchant_label
    merchants.map(&:name).sort.join(", ").presence
  end

  def card_type_label
    card_types.map(&:name).sort.join(", ").presence
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

  def card_base_fee_percent
    @card_base_fee_percent || Percentage.rate_to_percent_string(card_base_fee_rate)
  end

  def card_base_fee_percent=(value)
    @card_base_fee_percent = value
    self.card_base_fee_rate = rate_or_raw(value)
  end

  def snapshot_attributes
    attributes.slice("id", "dealer_id", "base_fee_rate", "card_base_fee_rate", "dealer_rate", "effective_from", "effective_until", "priority")
      .merge("merchant_ids" => merchant_ids, "card_type_ids" => card_type_ids, "specificity_level" => specificity_level)
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

  def targets_merchants?
    fee_rule_merchants.any?
  end

  def targets_card_types?
    fee_rule_card_types.any?
  end

  def merchant_belongs_to_dealer
    return if dealer_id.blank?

    merchants.each do |household|
      next if household.dealer_id.blank? || household.dealer_id == dealer_id

      errors.add(:merchant_ids, :dealer_mismatch)
      break
    end
  end

  def clear_card_base_fee_without_card_types
    self.card_base_fee_rate = nil unless targets_card_types?
  end

  # Same dealer, same priority, and overlapping dates are ambiguous when both
  # the household sets and the card-type sets collide. An empty set means every
  # value and only collides with another empty set.
  def no_overlapping_rule_with_same_precedence
    return unless active? && effective_from.present? && priority.present?

    overlapping = FeeRule.active
      .where(dealer_id: dealer_id, priority: priority)
      .where.not(id: id)
      .where("effective_until IS NULL OR effective_until > ?", effective_from)
    overlapping = overlapping.where("effective_from < ?", effective_until) if effective_until.present?

    mine_merchants = merchant_ids.map(&:to_i)
    mine_cards = card_type_ids.map(&:to_i)
    clash = overlapping.includes(:fee_rule_merchants, :fee_rule_card_types).detect do |other|
      sets_overlap?(mine_merchants, other.fee_rule_merchants.map(&:merchant_id)) &&
        sets_overlap?(mine_cards, other.fee_rule_card_types.map(&:card_type_id))
    end
    errors.add(:base, :overlapping_rule, id: clash.id) if clash
  end

  def sets_overlap?(mine, theirs)
    return true if mine.empty? && theirs.empty?

    mine.intersect?(theirs)
  end

  def self.covering_sql(table, id)
    column = COVERING_JOINS.fetch(table)
    unrestricted = "NOT EXISTS (SELECT 1 FROM #{table} WHERE #{table}.fee_rule_id = fee_rules.id)"
    return unrestricted if id.nil?

    covered = sanitize_sql_array([
      "EXISTS (SELECT 1 FROM #{table} WHERE #{table}.fee_rule_id = fee_rules.id AND #{table}.#{column} = ?)",
      id
    ])
    "#{unrestricted} OR #{covered}"
  end
end
