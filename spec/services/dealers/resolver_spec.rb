require "rails_helper"

RSpec.describe Dealers::Resolver do
  let(:merchant) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001") }
  let(:chuong) { create(:dealer, name: "Chương") }

  it "resolves the TID agent under the merchant" do
    link = create(:merchant_dealer, merchant: merchant, dealer: chuong, tid_key: "tid1")
    result = described_class.call(merchant: merchant, tid_key: "tid1")

    expect(result).to be_resolved
    expect(result.dealer).to eq(chuong)
    expect(result.merchant_dealer).to eq(link)
    expect(result.source).to eq("tid")
  end

  it "returns dealer_unmapped without a merchant" do
    result = described_class.call(merchant: nil, tid_key: "tid1")
    expect(result).not_to be_resolved
    expect(result.issue).to eq("dealer_unmapped")
  end

  it "returns dealer_unmapped without a tid_key" do
    result = described_class.call(merchant: merchant, tid_key: nil)
    expect(result).not_to be_resolved
    expect(result.issue).to eq("dealer_unmapped")
  end

  it "returns dealer_unmapped when the TID is not mapped" do
    result = described_class.call(merchant: merchant, tid_key: "tid9")
    expect(result).not_to be_resolved
    expect(result.issue).to eq("dealer_unmapped")
  end

  it "returns dealer_inactive for an inactive agent" do
    create(:merchant_dealer, merchant: merchant, dealer: chuong, tid_key: "tid1")
    chuong.update!(active: false)
    result = described_class.call(merchant: merchant, tid_key: "tid1")
    expect(result.dealer).to eq(chuong)
    expect(result.issue).to eq("dealer_inactive")
  end
end
