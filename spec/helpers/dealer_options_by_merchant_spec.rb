require "rails_helper"

RSpec.describe ApplicationHelper, "#dealer_options_by_merchant" do
  let(:nct) { create(:merchant, name: "HKD NCT", code: "NCT001") }
  let(:nct_mbv) { create(:merchant, name: "HKD NCT MBV", code: "NCTMBV001") }
  let(:men) { create(:dealer, name: "Chị Mến", code: "MEN") }
  let(:son) { create(:dealer, name: "Sơn", code: "SON") }
  let(:hai) { create(:dealer, name: "Anh Hải", code: "HAI") }

  before do
    create(:merchant_dealer, merchant: nct, dealer: men, tid_key: "tid1")
    create(:merchant_dealer, merchant: nct, dealer: hai, tid_key: "tid2")
    create(:merchant_dealer, merchant: nct_mbv, dealer: son, tid_key: "tid1")
  end

  it "lists each HKD's own agents, so the form can follow a corrected HKD" do
    options = helper.dealer_options_by_merchant

    expect(options[nct.id.to_s]).to eq([ [ "Anh Hải", hai.id ], [ "Chị Mến", men.id ] ])
    expect(options[nct_mbv.id.to_s]).to eq([ [ "Sơn", son.id ] ])
  end

  it "offers every dealer when no HKD is picked" do
    expect(helper.dealer_options_by_merchant[""].map(&:last)).to contain_exactly(men.id, son.id, hai.id)
  end

  it "marks inactive dealers" do
    son.update!(active: false)
    expect(helper.dealer_options_by_merchant[nct_mbv.id.to_s].first.first).to include("Sơn (")
  end
end
