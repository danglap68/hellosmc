FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    name { Faker::Name.name }
    password { "Password-12345" }
    password_confirmation { password }
    role { "operator" }
    active { true }

    trait(:admin) { role { "admin" } }
    trait(:operator) { role { "operator" } }
    trait(:viewer) { role { "viewer" } }
    trait(:inactive) { active { false } }
  end
end
