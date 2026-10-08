FactoryBot.define do
  factory :fee_rule do
    base_fee_rate { BigDecimal("0.0088") }
    effective_from { Time.zone.local(2026, 1, 1) }
    priority { 100 }
    active { true }

    transient do
      merchant { nil }
      card_type { nil }
    end

    after(:build) do |rule, evaluator|
      rule.merchants = [ evaluator.merchant ] if evaluator.merchant
      rule.card_types = [ evaluator.card_type ] if evaluator.card_type
    end
  end
end
