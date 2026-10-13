require "rails_helper"

# Two HKDs that print the same name on different banks' slips: the bank brand on the
# bill (bill_bank_name) picks one, through an alias "<bank> <name>".
RSpec.describe "Bank brand on the bill" do
  include_context "accounting setup"

  let!(:nct) { create(:merchant, name: "HKD NCT", code: "NCT") }
  let!(:nct_mbv) { create(:merchant, name: "HKD NCT MBV", code: "NCTMBV") }
  let(:tuan) { create(:dealer, name: "Tuân", code: "TUAN") }
  let(:nghiep) { create(:dealer, name: "Nghiệp", code: "NGHIEP") }

  before do
    create(:merchant_alias, merchant: nct, alias: "HKD NCT")
    create(:merchant_alias, merchant: nct_mbv, alias: "MBV HKD NCT")
    create(:merchant_dealer, merchant: nct, dealer: nghiep, tid_key: "tid3")
    create(:merchant_dealer, merchant: nct_mbv, dealer: tuan, tid_key: "tid3")
  end

  def document(bank:, name: "HKD NCT-3")
    { "merchant_name" => name, "bill_bank_name" => bank, "terminal_or_merchant_id" => "22031166" }
  end

  it "picks the HKD that has an alias '<bank> <name>' when the bill shows that bank" do
    result = Merchants::Resolver.for_document(document(bank: "MBV"))

    expect(result.merchant).to eq(nct_mbv)
    expect(result).to be_exact
    expect(Dealers::Resolver.call(merchant: result.merchant, merchant_name: "HKD NCT-3").dealer).to eq(tuan)
  end

  it "takes the plain HKD for another bank or none, as before" do
    expect(Merchants::Resolver.for_document(document(bank: "MB")).merchant).to eq(nct)
    expect(Merchants::Resolver.for_document(document(bank: nil)).merchant).to eq(nct)
  end

  it "does not let the bank turn an unknown name into a match" do
    expect(Merchants::Resolver.for_document(document(bank: "MBV", name: "HKD KHAC-1")).merchant).to be_nil
  end

  describe "the review reason when the bank is missing" do
    def evaluate(doc)
      base = extraction_fixture("normal_settlement")["documents"].first.merge(
        "merchant_name" => doc["merchant_name"], "bill_bank_name" => doc["bill_bank_name"],
        "terminal_or_merchant_id" => doc["terminal_or_merchant_id"]
      )
      Transactions::Evaluator.call(document: base, bill_image: analyzed_bill)
    end

    it "sends a bill without a bank to review when another HKD has a '<bank> <name>' alias" do
      expect(evaluate(document(bank: nil)).review_reasons).to include("merchant_bank_missing")
    end

    it "does not when the bank is read" do
      expect(evaluate(document(bank: "MBV")).review_reasons).not_to include("merchant_bank_missing")
      expect(evaluate(document(bank: "MB")).review_reasons).not_to include("merchant_bank_missing")
    end

    it "does not for an HKD nobody shares a name with" do
      doc = document(bank: nil, name: "001_ HỘ KINH DOANH THIÊN KIM GV-1")
      expect(evaluate(doc).review_reasons).not_to include("merchant_bank_missing")
    end
  end
end
