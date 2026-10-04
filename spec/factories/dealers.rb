FactoryBot.define do
  factory :dealer do
    sequence(:name) { |n| "Dealer #{n}" }
    sequence(:code) { |n| "D#{n}" }
    active { true }
  end
end
