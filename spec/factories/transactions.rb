FactoryBot.define do
  factory :transaction do
    bill_image
    telegram_message { bill_image&.telegram_message }
    sequence(:source_index) { |n| n }
    dealer
    merchant { association :merchant, dealer: dealer }
    card_type factory: :normal_card_type
    lot_number { "000269" }
    transaction_at { Time.zone.local(2026, 10, 4, 10, 57, 25) }
    transaction_amount_vnd { 10_000_000 }
    status { "needs_review" }
    confidence_score { BigDecimal("0.95") }
    source_data { { "review_reasons" => [ "merchant_low_confidence" ] } }

    trait :calculated do
      applied_base_fee_rate { BigDecimal("0.0088") }
      amount_after_base_fee_vnd { 9_912_000 }
      calculation_data { { "formula" => "transaction_amount * (1 - base_fee_rate)" } }
    end

    trait :approved do
      calculated
      status { "approved" }
      approved_at { Time.current }
    end

    trait :hold do
      status { "hold" }
    end
  end
end
