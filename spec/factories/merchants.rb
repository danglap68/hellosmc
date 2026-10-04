FactoryBot.define do
  factory :merchant do
    sequence(:name) { |n| "HỘ KINH DOANH MẪU #{n}" }
    sequence(:code) { |n| "M#{n}" }
    dealer
    active { true }
  end

  factory :merchant_alias do
    merchant
    sequence(:alias) { |n| "ALIAS #{n}" }
    alias_type { "receipt_name" }
    active { true }
  end
end
