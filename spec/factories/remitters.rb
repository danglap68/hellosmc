FactoryBot.define do
  factory :remitter do
    sequence(:name) { |n| "Remitter #{n}" }
    sequence(:excel_key) { |n| "KEY#{n}" }
    active { true }
  end
end
