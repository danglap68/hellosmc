FactoryBot.define do
  factory :telegram_chat do
    sequence(:telegram_chat_id) { |n| -1_001_000_000_000 - n }
    name { "Bill group" }
    chat_type { "supergroup" }
    dealer
    active { true }
  end
end
