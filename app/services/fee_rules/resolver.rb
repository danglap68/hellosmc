module FeeRules
  # Finds the single fee rule that applies to a transaction.
  #
  # Specificity (most specific first):
  #   1. merchant + card type   2. dealer + card type   3. merchant
  #   4. dealer                 5. card type only       6. system default
  # Within the most specific level that has matches, the lowest `priority`
  # number wins. A tie is an ambiguity and is reported, never guessed.
  class Resolver
    Result = Data.define(:fee_rule, :status, :level, :candidates) do
      def resolved?
        status == :resolved
      end

      def ambiguous?
        status == :ambiguous
      end
    end

    def self.call(merchant:, dealer:, card_type:, at:)
      new(merchant: merchant, dealer: dealer, card_type: card_type, at: at).call
    end

    # Money inputs for one transaction.
    #   rate        base fee used for "số tiền sau khi trừ phí gốc"
    #   rule        the rule that gave that rate (the winning rule or a borrowed card rule)
    #   card_rate   the rate to store as the card base fee, nil when the rate is just the household base
    #   dealer_rate dealer rate that goes with the rule that gave the base fee
    #   tied        several card rules were equally specific; the oldest was used and a reviewer must confirm
    BaseFee = Data.define(:rate, :rule, :card_rate, :dealer_rate, :tied) do
      def tied?
        tied
      end
    end

    # A card rule found for a household rule that does not list the card.
    CardRuleMatch = Data.define(:rule, :tied)

    # The household rule often does not list this card. The rate then comes from the
    # most specific rule that explicitly lists this card type.
    def self.explicit_card_rule(**args)
      explicit_card_match(**args)&.rule
    end

    # Most specific level wins (a rule configured with the household beats a card-only rule),
    # then the lowest priority number. Rules still equal after that are a tie: the oldest rule is
    # used and `tied` is set so the transaction cannot be auto-approved.
    def self.explicit_card_match(merchant:, dealer:, card_type:, at:, except: nil)
      return nil if card_type.nil? || at.nil?

      rules = FeeRule.active.effective_at(at)
        .assigned_to_card_type(card_type.id)
        .covering_merchant(merchant&.id)
        .where(dealer_id: [ nil, dealer&.id ].uniq)
        .includes(:fee_rule_merchants, :fee_rule_card_types)
        .to_a
      rules = rules.reject { |rule| rule.id == except.id } if except
      return nil if rules.empty?

      level_rules = rules.group_by(&:specificity_rank).min_by(&:first).last
      best_priority = level_rules.map(&:priority).min
      chosen = level_rules.select { |rule| rule.priority == best_priority }
      CardRuleMatch.new(rule: chosen.min_by(&:id), tied: chosen.size > 1)
    end

    # Rate for "số tiền sau khi trừ phí gốc".
    # A household rule that lists this card prices it itself (card base fee, else its base fee).
    # A household rule that does not list this card borrows another rule that does, else uses its base fee.
    def self.amount_base_fee(rule:, merchant:, dealer:, card_type:, at:)
      return BaseFee.new(rate: nil, rule: nil, card_rate: nil, dealer_rate: nil, tied: false) unless rule

      if rule.fee_rule_merchants.any? && !card_listed?(rule, card_type)
        match = explicit_card_match(merchant:, dealer:, card_type:, at:, except: rule)
        return build_base_fee(rule, rule, rule.base_fee_rate) unless match

        other = match.rule
        return build_base_fee(rule, other, other.card_base_fee_rate || other.base_fee_rate, tied: match.tied)
      end

      build_base_fee(rule, rule, rule.card_base_fee_rate || rule.base_fee_rate, own_card_field: rule.card_base_fee_rate.present?)
    end

    # Base fee of the household's own rule for a normal card. The export uses it to pick the sheet
    # when the winning rule is a card rule that does not carry the household tier.
    # Rules that list the normal card beat rules with no card list, then the lowest priority number.
    # Nil when there is no such rule or when equally ranked rules disagree.
    def self.household_base_fee_rate(merchant:, at:)
      return nil if merchant.nil? || at.nil?

      normal_id = CardType.find_by(key: "normal")&.id
      rules = FeeRule.active.effective_at(at).assigned_to_merchant(merchant.id).includes(:fee_rule_card_types).to_a
      rules = rules.select do |rule|
        ids = rule.fee_rule_card_types.map(&:card_type_id)
        ids.empty? || (normal_id && ids.include?(normal_id))
      end
      return nil if rules.empty?

      ranked = rules.group_by { |rule| rule.fee_rule_card_types.any? ? 0 : 1 }.min_by(&:first).last
      best_priority = ranked.map(&:priority).min
      rates = ranked.select { |rule| rule.priority == best_priority }.map(&:base_fee_rate).uniq
      rates.one? ? rates.first : nil
    end

    # The dealer rate follows the rule that gave the base fee. A source without its own
    # dealer rate keeps the winning rule's.
    def self.build_base_fee(rule, source, rate, tied: false, own_card_field: false)
      borrowed = source.id != rule.id
      BaseFee.new(
        rate: rate,
        rule: source,
        card_rate: (rate if borrowed || own_card_field),
        dealer_rate: borrowed && source.dealer_rate.present? ? source.dealer_rate : rule.dealer_rate,
        tied: tied
      )
    end
    private_class_method :build_base_fee

    def self.card_listed?(rule, card_type)
      card_type.present? && rule.card_type_ids.include?(card_type.id)
    end
    private_class_method :card_listed?

    def initialize(merchant:, dealer:, card_type:, at:)
      @merchant = merchant
      @dealer = dealer
      @card_type = card_type
      @at = at
    end

    def call
      return Result.new(fee_rule: nil, status: :not_found, level: nil, candidates: []) if @at.nil?

      rules = candidates.to_a
      return Result.new(fee_rule: nil, status: :not_found, level: nil, candidates: []) if rules.empty?

      level_rules = rules.group_by(&:specificity_rank).min_by(&:first).last
      best_priority = level_rules.map(&:priority).min
      top = level_rules.select { |rule| rule.priority == best_priority }
      level = top.first.specificity_level

      if top.size > 1
        Result.new(fee_rule: nil, status: :ambiguous, level: level, candidates: top)
      else
        Result.new(fee_rule: top.first, status: :resolved, level: level, candidates: level_rules)
      end
    end

    private

    # Every targeting dimension set on a rule must match the transaction.
    def candidates
      FeeRule.active.effective_at(@at)
        .covering_merchant(@merchant&.id)
        .covering_card_type(@card_type&.id)
        .where(dealer_id: [ nil, @dealer&.id ].uniq)
        .includes(:fee_rule_merchants, :fee_rule_card_types)
    end
  end
end
