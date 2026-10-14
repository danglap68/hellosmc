require "rails_helper"

RSpec.describe "SMC visual fixture capture", type: :request do
  it "captures the updated screens with local fixture data" do
    admin = create(:user, :admin)
    %w[approved needs_review hold processing failed].each_with_index do |status, index|
      create(:transaction, :calculated, bill_image: nil, telegram_message: nil,
        status: status, transaction_at: Time.current - index.hours,
        transaction_amount_vnd: [39998000, 25000000, 12000000, 8000000, 5000000][index],
        profit_amount_vnd: 99995, amount_after_base_fee_vnd: 39538023)
    end
    sign_in admin
    { dashboard: admin_root_path, week: admin_root_path(period: "7d"), transactions: admin_transactions_path,
      dealers: admin_settings_organization_dealers_path }.each do |name, path|
      get path
      expect(response).to have_http_status(:ok)
      File.write("/tmp/smc-preview/#{name}.html", response.body)
    end
  end
end
