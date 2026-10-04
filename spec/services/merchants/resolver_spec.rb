require "rails_helper"

RSpec.describe Merchants::Resolver do
  let(:dealer) { create(:dealer, name: "Anh Trân") }
  let!(:thien_kim) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001", dealer: dealer) }

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
    let(:other_dealer) { create(:dealer) }

    before { create(:merchant, name: "HKD THIÊN KIM GV", code: "999", dealer: other_dealer) }

    it "is ambiguous when two merchants share the same core name" do
      result = described_class.call(merchant_name: "HỘ KINH DOANH THIÊN KIM GV")
      expect(result).to be_ambiguous
      expect(result.candidates.size).to eq(2)
    end

    it "is resolved when the configured dealer narrows it to one" do
      result = described_class.call(merchant_name: "HỘ KINH DOANH THIÊN KIM GV", dealer: dealer)
      expect(result.merchant).to eq(thien_kim)
    end
  end
end
