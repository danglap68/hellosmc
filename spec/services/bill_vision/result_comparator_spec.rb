require "rails_helper"

RSpec.describe BillVision::ResultComparator do
  def normalize(data)
    BillVision::Normalizer.call(data, provider: "openai", model: "fixture")
  end

  it "compares normalized dates, times and Vietnamese merchant text" do
    primary = extraction_fixture("normal_settlement")
    validator = primary.deep_dup
    validator["documents"][0].merge!("transaction_date" => "04/10/2026", "transaction_time" => "10:57:25",
                                    "merchant_name" => "001_ ho kinh doanh thien kim gv")
    expect(described_class.call(primary: normalize(primary), validator: normalize(validator)).agreed).to be(true)
  end

  it "matches reordered documents one-to-one and detects omitted documents" do
    primary = extraction_fixture("two_settlements")
    validator = primary.deep_dup
    validator["documents"].reverse!
    expect(described_class.call(primary: normalize(primary), validator: normalize(validator)).agreed).to be(true)
    validator["documents"].pop
    expect(described_class.call(primary: normalize(primary), validator: normalize(validator)).differences).to include("document_count")
  end

  it "treats conflicting MID/TID as disagreement even if names agree" do
    primary = extraction_fixture("normal_settlement")
    validator = primary.deep_dup
    primary["documents"][0]["terminal_or_merchant_id"] = "0001-23"
    validator["documents"][0]["terminal_or_merchant_id"] = "000124"
    expect(described_class.call(primary: normalize(primary), validator: normalize(validator)).differences).to include("merchant_identity")
  end

  it "does not mistake absent merchant names for matching identities" do
    primary = extraction_fixture("normal_settlement")
    primary["documents"][0].merge!("merchant_name" => nil, "terminal_or_merchant_id" => "MID001")
    validator = primary.deep_dup
    validator["documents"][0]["terminal_or_merchant_id"] = nil
    expect(described_class.call(primary: normalize(primary), validator: normalize(validator)).differences).to include("merchant_identity")
  end
end
