require "rails_helper"

RSpec.describe "Review reasons from the workbook writer" do
  let(:merchant) { create(:merchant, name: "Cherry Coffee") }
  let(:transaction) do
    create(:transaction, merchant: merchant, status: "needs_review",
                         source_data: { "review_reasons" => [ "ds_header_dealer_unmatched" ] })
  end

  it "explains the reason and links to the HKD's agents" do
    sign_in create(:user, :admin)

    get admin_transaction_path(transaction)

    expect(response.body).to include("cột đại lý trong DS MB ghi tên người chưa có trong hệ thống")
    expect(response.body).to include(%(href="#{edit_admin_merchant_path(merchant)}"), "Cập nhật đại lý của HKD")
  end

  it "shows the reason without the link to someone who cannot edit HKDs" do
    sign_in create(:user, :viewer)

    get admin_transaction_path(transaction)

    expect(response.body).to include("cột đại lý trong DS MB ghi tên người chưa có trong hệ thống")
    expect(response.body).not_to include("Cập nhật đại lý của HKD")
  end
end
