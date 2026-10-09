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

    # The household rule often does not list this card. The rate then comes from the
    # most specific rule that explicitly lists this card type.
    def self.explicit_card_rule(merchant:, dealer:, card_type:, at:, except: nil)
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
      chosen.one? ? chosen.first : nil
    end

    # Rate for "số tiền sau khi trừ phí gốc".
    # A household rule that lists this card prices it itself (card base fee, else its base fee).
    # A household rule that does not list this card borrows another rule that does, else uses its base fee.
    def self.amount_base_fee(rule:, merchant:, dealer:, card_type:, at:)
      return [ nil, nil ] unless rule

      if rule.fee_rule_merchants.any?
        return [ rule.card_base_fee_rate || rule.base_fee_rate, rule ] if card_listed?(rule, card_type)

        other = explicit_card_rule(merchant:, dealer:, card_type:, at:, except: rule)
        return [ other.card_base_fee_rate || other.base_fee_rate, other ] if other

        return [ rule.base_fee_rate, rule ]
      end

      [ rule.card_base_fee_rate || rule.base_fee_rate, rule ]
    end

    # Phí đại lý đi cùng rule đã cho phí gốc. Rule nguồn không có phí đại lý thì giữ của rule thắng.
    def self.amount_dealer_rate(rule:, source:)
      return nil unless rule

      if source && source.id != rule.id && source.dealer_rate.present?
        source.dealer_rate
      else
        rule.dealer_rate
      end
    end

    # Stored only when this rate came from a card rule or from the card-base field.
    def self.applied_card_rate(rule:, rate:, source:)
      return nil unless rule && source && rate

      from_other_rule = source.id != rule.id
      from_card_field = rule.card_base_fee_rate.present? && rate == rule.card_base_fee_rate
      rate if from_other_rule || from_card_field
    end

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
