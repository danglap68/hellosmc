FactoryBot.define do
  factory :bill_album do
    telegram_chat
    sequence(:media_group_id) { |n| "media-group-#{n}" }
    status { "collecting" }
    collect_until { 1.hour.ago }
  end
end
