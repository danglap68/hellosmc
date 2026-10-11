require "rails_helper"

RSpec.describe BillVision::ValidationPolicy do
  include_context "accounting setup"

  def decision_for(bill)
    described_class.call(normalized: bill.normalized_extraction, bill_image: bill)
  end

  it "treats an HKD outside the group's list as a configuration problem" do
    chat.merchants << create(:merchant)
    decision = decision_for(analyzed_bill)
    expect(decision.deterministic_business_review_reasons).to include("merchant_not_in_chat")
    expect(decision).not_to be_validate
  end

  it "treats an agent mismatch between title and TID as a configuration problem" do
    other = create(:dealer, name: "Chị Lan")
    chat.update!(name: "Chị Lan-Thiên Kim GV")
    create(:merchant_dealer, merchant: merchant, dealer: other, tid_key: "tid2")
    expect(decision_for(analyzed_bill).deterministic_business_review_reasons).to include("dealer_group_mismatch")
  end

  it "does not reread a bank transfer for the merchant or time it never prints" do
    data = extraction_fixture("transfer").tap { |d| d["documents"][0]["transaction_time"] = nil }
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")

    decision = described_class.call(normalized: normalized)

    expect(decision.visual_validation_reasons).to be_empty
    expect(decision).not_to be_validate
  end

  it "still rereads a transfer whose amount is missing" do
    data = extraction_fixture("transfer").tap { |d| d["documents"][0]["total_amount_vnd"] = nil }
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")

    expect(described_class.call(normalized: normalized).visual_validation_reasons).to include("amount_unreadable")
  end

  it "still rereads a settlement without merchant or time" do
    data = extraction_fixture("normal_settlement").tap do |d|
      d["documents"][0].merge!("merchant_name" => nil, "terminal_or_merchant_id" => nil, "transaction_time" => nil)
    end
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")

    expect(described_class.call(normalized: normalized).visual_validation_reasons)
      .to include("merchant_unreadable", "transaction_time_unreadable")
  end

  it "reports nothing when the HKD is in the group's list" do
    chat.merchants << merchant
    expect(decision_for(analyzed_bill).deterministic_business_review_reasons).not_to include("merchant_not_in_chat")
  end
end
