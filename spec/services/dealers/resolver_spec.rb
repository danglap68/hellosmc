require "rails_helper"

RSpec.describe Dealers::Resolver do
  let(:merchant) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001") }
  let(:chuong) { create(:dealer, name: "Chương") }

  it "resolves the TID agent under the merchant" do
    link = create(:merchant_dealer, merchant: merchant, dealer: chuong, tid_key: "tid1")
    result = described_class.call(merchant: merchant, merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1")

    expect(result).to be_resolved
    expect(result.dealer).to eq(chuong)
    expect(result.merchant_dealer).to eq(link)
    expect(result.source).to eq("tid")
  end

  it "returns dealer_unmapped without a merchant" do
    result = described_class.call(merchant: nil, merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1")
    expect(result).not_to be_resolved
    expect(result.issue).to eq("dealer_unmapped")
  end

  it "returns dealer_unmapped without a tid" do
    result = described_class.call(merchant: merchant, merchant_name: "HỘ KINH DOANH THIÊN KIM GV")
    expect(result).not_to be_resolved
    expect(result.issue).to eq("dealer_unmapped")
  end

  it "returns dealer_unmapped when the TID is not mapped" do
    result = described_class.call(merchant: merchant, merchant_name: "HỘ KINH DOANH THIÊN KIM GV-9")
    expect(result).not_to be_resolved
    expect(result.issue).to eq("dealer_unmapped")
  end

  it "returns dealer_inactive for an inactive agent" do
    create(:merchant_dealer, merchant: merchant, dealer: chuong, tid_key: "tid1")
    chuong.update!(active: false)
    result = described_class.call(merchant: merchant, merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1")
    expect(result.dealer).to eq(chuong)
    expect(result.issue).to eq("dealer_inactive")
  end

  describe "with the receiving account holder of a bank transfer" do
    let(:son) { create(:dealer, name: "Sơn") }
    let(:lan) { create(:dealer, name: "Chị Lan") }
    let!(:son_link) { create(:merchant_dealer, merchant: merchant, dealer: son, tid_key: "tid1") }
    let!(:lan_link) { create(:merchant_dealer, merchant: merchant, dealer: lan, tid_key: "tid2") }

    def resolve(recipient, name: "")
      described_class.call(merchant: merchant, merchant_name: name, recipient_name: recipient)
    end

    it "picks the agent named by the recipient when nothing else says who it is" do
      result = resolve("TRAN NGUYEN KHANH SON")
      expect(result).to be_resolved
      expect(result.dealer).to eq(son)
      expect(result.source).to eq("recipient")
    end

    it "matches whole words only" do
      create(:merchant_dealer, merchant: merchant, dealer: create(:dealer, name: "An"), tid_key: "tid5")
      expect(resolve("NGUYEN VAN ANH").issue).to eq("dealer_unmapped")
    end

    it "gives no hint when two agents match the name" do
      other = create(:dealer, name: "Khánh Sơn")
      create(:merchant_dealer, merchant: merchant, dealer: other, tid_key: "tid3")
      expect(resolve("TRAN NGUYEN KHANH SON")).not_to be_resolved
    end

    it "ignores a recipient that names no agent of this HKD" do
      expect(resolve("CONG TY ABC").issue).to eq("dealer_unmapped")
    end

    it "accepts a recipient that agrees with the TID" do
      result = resolve("TRAN NGUYEN KHANH SON", name: "HỘ KINH DOANH THIÊN KIM GV-1")
      expect(result.dealer).to eq(son)
      expect(result.source).to eq("tid")
    end

    it "rejects a recipient that disagrees with the TID" do
      result = resolve("TRAN NGUYEN KHANH SON", name: "HỘ KINH DOANH THIÊN KIM GV-2")
      expect(result.dealer).to be_nil
      expect(result.issue).to eq("dealer_recipient_mismatch")
    end

    it "does not override an unmapped TID" do
      expect(resolve("TRAN NGUYEN KHANH SON", name: "HỘ KINH DOANH THIÊN KIM GV-9").issue).to eq("dealer_unmapped")
    end

    it "needs a single TID row for the agent, otherwise it stays unmapped" do
      create(:merchant_dealer, merchant: merchant, dealer: son, tid_key: "tid4")
      expect(resolve("TRAN NGUYEN KHANH SON").issue).to eq("dealer_unmapped")
    end
  end
end
