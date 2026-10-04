FactoryBot.define do
  factory :card_type do
    sequence(:key) { |n| "card#{n}" }
    name { key.upcase }
    active { true }

    initialize_with { CardType.find_or_initialize_by(key: key) }

    factory :normal_card_type do
      key { "normal" }
      name { "Thẻ thường" }
      aliases { [ "normal" ] }
    end

    factory :mb_card_type do
      key { "mb" }
      name { "MB" }
      aliases { [ "mb" ] }
    end

    factory :napas_card_type do
      key { "napas" }
      name { "Napas" }
      aliases { [ "napas" ] }
    end
  end
end
