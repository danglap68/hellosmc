require "rails_helper"

RSpec.describe "Dealers" do
  let(:merchant) { create(:merchant, name: "HKD AS CAFE-CAFE MILO", code: "MILO001") }
  let(:hue) { create(:dealer, name: "Chị Huệ", code: "CHIHUE") }

  before do
    sign_in create(:user, :admin)
    [ "tid127", "tid128", "tid129" ].each do |tid|
      create(:merchant_dealer, merchant: merchant, dealer: hue, tid_key: tid, tid_label: tid.upcase)
    end
  end

  it "lists an HKD once with all of the agent's TIDs" do
    get admin_dealer_path(hue)
    expect(response.body.scan("HKD AS CAFE-CAFE MILO").size).to eq(1)
    expect(response.body).to include("TID127", "TID128", "TID129")
  end

  it "counts distinct HKDs on the index" do
    get admin_dealers_path
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(controller.instance_variable_get(:@merchant_counts)[hue.id]).to eq(1)
  end
end
