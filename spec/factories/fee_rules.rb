FactoryBot.define do
  factory :fee_rule do
    base_fee_rate { BigDecimal("0.0088") }
    effective_from { Time.zone.local(2026, 1, 1) }
    priority { 100 }
    active { true }
  end
end
