require "rails_helper"

RSpec.describe MerchantDealer do
  describe "validations" do
    it "requires the TID, without which the DS MB header cannot be filled in" do
      md = build(:merchant_dealer, tid_key: nil, ds_header: nil)
      expect(md).not_to be_valid
      expect(md.errors[:tid_key]).to be_present
      expect(md.errors[:ds_header]).to be_present
    end

    it "fills the sheet names the client does not know (M1)" do
      merchant = create(:merchant)
      create(:merchant_dealer, merchant: merchant, tid_key: "tid1", ds_sheet_anchor: "Thiên Kim GV")
      md = build(:merchant_dealer, merchant: merchant.reload, dealer: create(:dealer, name: "Sơn"), tid_key: "2",
                                   ds_sheet_anchor: nil, ds_header: nil, rd_agent_label: nil)

      expect(md).to be_valid
      expect(md).to have_attributes(ds_sheet_anchor: "Thiên Kim GV", ds_header: "Sơn (tid2)", rd_agent_label: "Sơn")
    end

    it "rebuilds hidden sheet names when the agent or TID of a row changes (M4)" do
      link = create(:merchant_dealer, dealer: create(:dealer, name: "Chương"), tid_key: "tid1",
                                      ds_header: "Chương (tid1)", rd_agent_label: "Chương", tid_label: "tid1")

      link.update!(dealer: create(:dealer, name: "Sơn"))
      expect(link).to have_attributes(ds_header: "Sơn (tid1)", rd_agent_label: "Sơn")

      link.update!(tid_key: "tid2")
      expect(link).to have_attributes(ds_header: "Sơn (tid2)", tid_label: "tid2", rd_agent_label: "Sơn")
    end

    it "keeps a sheet name edited together with the agent change" do
      link = create(:merchant_dealer, dealer: create(:dealer, name: "Chương"), tid_key: "tid1")

      link.update!(dealer: create(:dealer, name: "Sơn"), ds_header: "Anh Sơn (tid1)")
      expect(link.ds_header).to eq("Anh Sơn (tid1)")
    end

    it "keeps names typed by hand (M3)" do
      md = build(:merchant_dealer, ds_header: "Sơn(tid2)", rd_agent_label: "Anh Sơn")
      md.valid?
      expect(md).to have_attributes(ds_header: "Sơn(tid2)", rd_agent_label: "Anh Sơn")
    end

    it "defaults tid_label to tid_key" do
      md = build(:merchant_dealer, tid_key: "tid1", tid_label: nil)
      md.valid?
      expect(md.tid_label).to eq("tid1")
    end

    it "requires the DS MB header anchor instead of guessing the merchant name (M2)" do
      merchant = create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV")
      md = build(:merchant_dealer, merchant: merchant, ds_sheet_anchor: nil)
      expect(md).not_to be_valid
      expect(md.errors[:ds_sheet_anchor]).to be_present
    end

    it "normalizes a bare number to a tid key" do
      md = build(:merchant_dealer, tid_key: "1")
      md.valid?
      expect(md.tid_key).to eq("tid1")
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
  describe "transfer code" do
    it "is tidied up: spaces dropped, upper-cased, blank means none" do
      expect(create(:merchant_dealer, transfer_code: " tk 05 ").transfer_code).to eq("TK05")
      expect(create(:merchant_dealer, transfer_code: "  ").transfer_code).to be_nil
    end

    it "must be letters then digits" do
      %w[TK 01 TK-01 TK01X].each do |bad|
        link = build(:merchant_dealer, transfer_code: bad)
        expect(link).not_to be_valid, "#{bad} should be refused"
        expect(link.errors[:transfer_code]).to be_present
      end
    end

    it "names exactly one agent row, whatever the case" do
      create(:merchant_dealer, transfer_code: "TK01")

      duplicate = build(:merchant_dealer, transfer_code: "tk01")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:transfer_code]).to be_present
    end

    it "lets several rows have no code" do
      create(:merchant_dealer, transfer_code: nil)
      expect(build(:merchant_dealer, transfer_code: nil)).to be_valid
    end
  end
end
