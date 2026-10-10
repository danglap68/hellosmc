require "rails_helper"

RSpec.describe MerchantDealer do
  describe "validations" do
    it "requires tid_key and the display fields" do
      md = build(:merchant_dealer, tid_key: nil, tid_label: nil, ds_sheet_anchor: nil,
                 ds_header: nil, rd_agent_label: nil)
      expect(md).not_to be_valid
      expect(md.errors[:tid_key]).to be_present
      expect(md.errors[:ds_sheet_anchor]).to be_present
    end

    it "normalizes tid_key from 'TID 127' to 'tid127'" do
      md = build(:merchant_dealer, tid_key: "TID 127")
      md.valid?
      expect(md.tid_key).to eq("tid127")
    end

    it "rejects two active rows with the same merchant and tid_key" do
      merchant = create(:merchant)
      create(:merchant_dealer, merchant: merchant, tid_key: "tid1")
      expect(build(:merchant_dealer, merchant: merchant, tid_key: "tid1")).not_to be_valid
    end

    it "allows the same dealer under multiple HKDs" do
      dealer = create(:dealer)
      create(:merchant_dealer, dealer: dealer, tid_key: "tid1")
      expect(build(:merchant_dealer, dealer: dealer, tid_key: "tid1")).to be_valid
    end
  end
end
