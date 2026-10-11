require "rails_helper"

# Real bill from DS_DAI_LY.docx: MB settlement slip printed
#   TÊN ĐẠI LÝ "CHERRY COFEE 2", TID 51060325, MID 106-C-098513,
#   batch 000203, JCB, 21,995,000 VND, 10/10/2026 08:43:24.
# The "2" in the name is the agent number; 51060325 is the physical terminal.
RSpec.describe "CHERRY COFEE 2 bill" do
  include_context "accounting setup"

  let(:agent) { create(:dealer, name: "Anh Cherry", code: "CHERRY") }
  let(:cherry) { create(:merchant, name: "002_ CHERRY COFEE", code: "002") }
  let(:bill) { analyzed_bill(extraction: "cherry_cofee_2_settlement") }

  def build_transaction
    Transactions::Builder.call(bill_image: bill).sole
  end

  describe "extraction" do
    it "reads the facts printed on the slip" do
      doc = bill.normalized_extraction["documents"].sole
      expect(doc).to include("document_type" => "settlement", "total_amount_vnd" => 21_995_000,
                             "lot_number" => "000203", "merchant_name" => "CHERRY COFEE 2",
                             "terminal_or_merchant_id" => "106-C-098513")
    end
  end

  describe "TID detection from the merchant name" do
    it "uses the bare trailing number" do
      expect(Workbook::TidParser.call("CHERRY COFEE 2")).to eq("tid2")
    end

    it "uses the number after a dash" do
      expect(Workbook::TidParser.call("CHERRY COFEE-2")).to eq("tid2")
    end

    it "never mistakes the physical terminal number for the agent" do
      expect(Workbook::TidParser.call("CHERRY COFEE")).to be_nil
    end
  end

  describe "merchant registered without the number" do
    before do
      create(:merchant_alias, merchant: cherry, alias: "CHERRY COFEE", alias_type: "receipt_name")
      create(:merchant_dealer, merchant: cherry, dealer: agent, tid_key: "tid2",
                               ds_sheet_anchor: "CHERRY COFEE", ds_header: "Anh Cherry (tid2)", rd_agent_label: "Anh Cherry")
    end

    it "resolves merchant and agent and approves" do
      transaction = build_transaction
      expect(transaction).to have_attributes(merchant: cherry, dealer: agent, lot_number: "000203",
                                             transaction_amount_vnd: 21_995_000)
      expect(transaction.transaction_at).to eq(Time.zone.local(2026, 10, 10, 8, 43, 24))
      expect(transaction.review_reason_codes).not_to include("dealer_unmapped", "merchant_not_found")
    end

    it "sends to review when the agent number is not mapped" do
      cherry.merchant_dealers.destroy_all
      transaction = build_transaction
      expect(transaction).to be_needs_review
      expect(transaction.review_reason_codes).to include("dealer_unmapped")
    end
  end

  describe "merchant registered with the number in its name" do
    before do
      cherry.update!(name: "002_ CHERRY COFEE 2")
      create(:merchant_alias, merchant: cherry, alias: "CHERRY COFEE 2", alias_type: "receipt_name")
      create(:merchant_dealer, merchant: cherry, dealer: agent, tid_key: "tid2",
                               ds_sheet_anchor: "CHERRY COFEE", ds_header: "Anh Cherry (tid2)", rd_agent_label: "Anh Cherry")
    end

    it "still resolves merchant and agent" do
      transaction = build_transaction
      expect(transaction.merchant).to eq(cherry)
      expect(transaction.dealer).to eq(agent)
    end
  end

  describe "resolution by MID" do
    it "finds the merchant from the printed MID even when the name is unknown" do
      create(:merchant_alias, merchant: cherry, alias: "106-C-098513", alias_type: "merchant_id")
      create(:merchant_dealer, merchant: cherry, dealer: agent, tid_key: "tid2",
                               ds_sheet_anchor: "CHERRY COFEE", ds_header: "Anh Cherry (tid2)", rd_agent_label: "Anh Cherry")
      expect(build_transaction.merchant).to eq(cherry)
    end

    it "does not guess an unknown merchant" do
      transaction = build_transaction
      expect(transaction.merchant).to be_nil
      expect(transaction).to be_needs_review
      expect(transaction.review_reason_codes).to include("merchant_not_found")
    end
  end

  describe "same name, different agent numbers" do
    it "keeps agents apart under one merchant" do
      other = create(:dealer, name: "Chị Lan", code: "LAN")
      create(:merchant_alias, merchant: cherry, alias: "CHERRY COFEE", alias_type: "receipt_name")
      create(:merchant_dealer, merchant: cherry, dealer: other, tid_key: "tid1",
                               ds_sheet_anchor: "CHERRY COFEE", ds_header: "Chị Lan (tid1)", rd_agent_label: "Chị Lan")
      create(:merchant_dealer, merchant: cherry, dealer: agent, tid_key: "tid2",
                               ds_sheet_anchor: "CHERRY COFEE", ds_header: "Anh Cherry (tid2)", rd_agent_label: "Anh Cherry")
      expect(build_transaction.dealer).to eq(agent)
    end
  end
end
