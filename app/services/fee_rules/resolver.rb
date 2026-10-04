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
        .where(merchant_id: [ nil, @merchant&.id ].uniq)
        .where(dealer_id: [ nil, @dealer&.id ].uniq)
        .where(card_type_id: [ nil, @card_type&.id ].uniq)
    end
  end
end
