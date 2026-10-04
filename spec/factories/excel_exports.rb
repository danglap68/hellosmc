FactoryBot.define do
  factory :excel_export do
    export_date { Date.new(2026, 10, 4) }
    end_date { export_date }
    status { "pending" }
  end
end
