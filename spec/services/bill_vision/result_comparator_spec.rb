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

  def compare(primary, validator)
    described_class.call(primary: normalize(primary), validator: normalize(validator))
  end

  it "accepts equivalent padded transfer memos but blocks conflicting or missing validator memos" do
    primary = extraction_fixture("transfer")
    primary["documents"].first.merge!("transfer_memo" => "As02", "transfer_memo_confidence" => 0.99)
    validator = primary.deep_dup
    validator["documents"].first["transfer_memo"] = "AS2"
    expect(compare(primary, validator).agreed).to be(true)
    [ "AS3", nil ].each do |memo|
      validator["documents"].first["transfer_memo"] = memo
      expect(compare(primary, validator).differences).to include("transfer_memo")
    end
  end

  describe "what blocks and what does not" do
    it "blocks when the amount, date, time or document type differ" do
      {
        "total_amount_vnd" => 11_445_001, "transaction_date" => "2026-10-05", "transaction_time" => "10:57:26",
        "document_type" => "child_receipt"
      }.each do |field, value|
        primary = extraction_fixture("normal_settlement")
        validator = primary.deep_dup
        validator["documents"][0][field] = value

        comparison = compare(primary, validator)
        expect(comparison.agreed).to be(false), "#{field} should block"
        expect(comparison.differences).to include(field)
      end
    end

    it "does not block when only the merchant name differs (TAN read as TAM)" do
      primary = extraction_fixture("normal_settlement")
      primary["documents"][0].merge!("merchant_name" => "GAT TAN DAY COFFEE 3", "terminal_or_merchant_id" => nil)
      validator = primary.deep_dup
      validator["documents"][0]["merchant_name"] = "GAT TAM DAY COFFEE 3"

      comparison = compare(primary, validator)
      expect(comparison.agreed).to be(true)
      expect(comparison.differences).to be_empty
      expect(comparison.soft_differences).to include("merchant_identity")
    end

    it "does not block when only the MID/TID conflicts, but records it" do
      primary = extraction_fixture("normal_settlement")
      validator = primary.deep_dup
      primary["documents"][0]["terminal_or_merchant_id"] = "0001-23"
      validator["documents"][0]["terminal_or_merchant_id"] = "000124"

      comparison = compare(primary, validator)
      expect(comparison.agreed).to be(true)
      expect(comparison.soft_differences).to include("merchant_identity")
    end

    it "does not block when only the lot number differs, but records it" do
      primary = extraction_fixture("normal_settlement")
      validator = primary.deep_dup
      validator["documents"][0]["lot_number"] = "000999"

      comparison = compare(primary, validator)
      expect(comparison.agreed).to be(true)
      expect(comparison.soft_differences).to include("lot_number")
    end

    it "records a merchant that only one model found, without blocking" do
      primary = extraction_fixture("normal_settlement")
      primary["documents"][0].merge!("merchant_name" => nil, "terminal_or_merchant_id" => "MID001")
      validator = primary.deep_dup
      validator["documents"][0]["terminal_or_merchant_id"] = nil

      comparison = compare(primary, validator)
      expect(comparison.agreed).to be(true)
      expect(comparison.soft_differences).to include("merchant_identity")
    end

    it "keeps a money difference blocking even when a soft one comes with it" do
      primary = extraction_fixture("normal_settlement")
      validator = primary.deep_dup
      validator["documents"][0].merge!("total_amount_vnd" => 1, "lot_number" => "000999")

      comparison = compare(primary, validator)
      expect(comparison.agreed).to be(false)
      expect(comparison.differences).to eq([ "total_amount_vnd" ])
      expect(comparison.soft_differences).to include("lot_number")
    end
  end

  it "does not call it a disagreement when neither model finds a merchant" do
    primary = extraction_fixture("normal_settlement")
    primary["documents"][0].merge!("merchant_name" => nil, "terminal_or_merchant_id" => nil)
    validator = primary.deep_dup

    comparison = compare(primary, validator)
    expect(comparison.differences).not_to include("merchant_identity")
    expect(comparison.soft_differences).not_to include("merchant_identity")
  end
end
