FactoryBot.define do
  factory :merchant_dealer do
    merchant
    dealer
    sequence(:tid_key) { |n| "tid#{n}" }
    sequence(:tid_label) { |n| "tid#{n}" }
    sequence(:ds_sheet_anchor) { |n| "HKD #{n}" }
    sequence(:ds_header) { |n| "Agent (tid#{n})" }
    sequence(:rd_agent_label) { |n| "Agent #{n}" }
    active { true }
  end
end
