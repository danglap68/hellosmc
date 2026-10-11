FactoryBot.define do
  factory :remitter_transfer do
    telegram_message
    remitter
    transferred_at { Time.current }
    status { "processing" }
  end
end
