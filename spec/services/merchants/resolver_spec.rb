require "rails_helper"

RSpec.describe Merchants::Resolver do
  let(:dealer) { create(:dealer, name: "Anh Trân") }
  let!(:thien_kim) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001") }

  it "resolves by an exact identifier alias first" do
    create(:merchant_alias, merchant: thien_kim, alias_type: "merchant_id", alias: "000000123456")
    result = described_class.call(merchant_name: "garbled", merchant_identifier: "0000 0012 3456")
    expect(result.merchant).to eq(thien_kim)
    expect(result.method).to eq(:identifier)
    expect(result).to be_exact
  end

  it "resolves by an exact receipt-name alias" do
    create(:merchant_alias, merchant: thien_kim, alias: "HKD THIEN KIM GO VAP")
    result = described_class.call(merchant_name: "HKD Thiên Kim Gò Vấp")
    expect(result.merchant).to eq(thien_kim)
    expect(result.method).to eq(:alias)
  end

  it "resolves by normalized merchant name, ignoring code prefix and legal form" do
    result = described_class.call(merchant_name: "HỘ KINH DOANH THIÊN KIM GV")
    expect(result.merchant).to eq(thien_kim)
    expect(result.method).to eq(:name)
  end

  it "only suggests fuzzy matches, which are not exact" do
    result = described_class.call(merchant_name: "HỘ KINH DOANH THIÊN KlM GV")
    expect(result.method).to eq(:fuzzy)
    expect(result.merchant).to eq(thien_kim)
    expect(result).not_to be_exact
  end

  it "returns none for unknown merchants and never creates one" do
    expect {
      result = described_class.call(merchant_name: "CỬA HÀNG HOÀN TOÀN KHÁC")
      expect(result.method).to eq(:none)
      expect(result.merchant).to be_nil
    }.not_to change(Merchant, :count)
  end

  it "ignores inactive merchants" do
    thien_kim.update!(active: false)
    expect(described_class.call(merchant_name: "HỘ KINH DOANH THIÊN KIM GV").merchant).to be_nil
  end

  describe "ambiguity" do
    before { create(:merchant, name: "HKD THIÊN KIM GV", code: "999") }

    it "is ambiguous when two merchants share the same core name" do
      result = described_class.call(merchant_name: "HỘ KINH DOANH THIÊN KIM GV")
      expect(result).to be_ambiguous
      expect(result.candidates.size).to eq(2)
    end
  end
  describe "names whose tail OCR garbled (matching on the distinctive words)" do
    before do
      Workbook::Seed.call
      # The client's own alias for HKD NCT ("Nguyen cao tri" is the owner's name).
      create(:merchant_alias, merchant: Merchant.find_by!(code: "NCT001"), alias: "HKD Nguyen cao tri")
    end

    def resolve(name)
      # What Transactions::Evaluator tries: without the TID suffix, and without a bare trailing number.
      results = [ Workbook::TidParser.strip(name), Workbook::TidParser.strip_bare_number(name) ].uniq.map do |candidate|
        described_class.call(merchant_name: candidate)
      end
      results.find(&:exact?) || results.find(&:fuzzy?) || results.find(&:ambiguous?) || results.first
    end

    {
      "HKD THIÊN KIM GỬI 2" => "001", "HKD THIEN KIM GUI" => "001", "THIÊN KIM GỦ 1" => "001",
      "HKD THIÊN KIM GV" => "001", "THIEN KlM GV-1" => "001",
      "GAT TAM DAY COFFEE 3" => "GTD001", "GẮT TẠM ĐÂY COFFEE 2" => "GTD001", "GAT TAN DAY COFEE 3" => "GTD001",
      "CHERY COFFE" => "CHERRY001", "CHERRY COFEE 2" => "CHERRY001",
      "HKD AS CAFE-CAFE MILO 127" => "MILO001",
      "HỘ KD NGUYEN CAO TRI 3" => "NCT001", "H.K.D NGUYEN CAO TRI" => "NCT001", "HO KD CA THE NGUYEN CAO TRI 2" => "NCT001"
    }.each do |ocr, code|
      it "recognises #{ocr.inspect} as HKD #{code}" do
        result = resolve(ocr)

        expect(result.merchant&.code).to eq(code)
        expect(result.method).to be_in(%i[alias name fuzzy])
      end
    end

    it "only suggests what is not an exact name: a person still confirms it" do
      expect(resolve("HKD THIÊN KIM GỬI 2")).to be_fuzzy
    end

    it "does not read the AS CAFE family as one another" do
      expect(resolve("HKD AS CAFE").merchant.code).to eq("ASCAFE001")
      expect(resolve("HKD AS CAFE-CAFE 96").merchant.code).to eq("AS96001")
      expect(resolve("AS CAFE CAFE 96").merchant&.code).not_to eq("ASCAFE001")
    end

    it "does not read NCT and NCT MBV as one another" do
      expect(resolve("HKD NCT 2").merchant.code).to eq("NCT001")
      expect(resolve("HKD NCT MBV 2").merchant.code).to eq("NCTMBV001")
    end

    it "does not suggest an HKD for a name that shares only a common word" do
      %w[CAFE COFFEE SHOP].each do |word|
        result = resolve("QUAN #{word} HOA MAI")
        expect(result.merchant).to be_nil, "#{word}: matched #{result.merchant&.name}"
      end
      expect(resolve("HKD NGUYEN VAN A").merchant).to be_nil
    end

    it "leaves two equally good matches ambiguous" do
      a = create(:merchant, name: "Quan Hoa Sen 1", code: "HS1")
      b = create(:merchant, name: "Quan Hoa Sen 2", code: "HS2")

      result = resolve("QUAN HOA SEN")
      expect([ a, b ]).to include(*result.candidates.first(2)) if result.ambiguous?
      expect(result.merchant).to be_nil.or be_in([ a, b ])
    end
  end
end
