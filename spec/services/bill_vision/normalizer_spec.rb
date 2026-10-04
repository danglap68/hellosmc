require "rails_helper"

RSpec.describe BillVision::Normalizer do
  def normalize(data)
    described_class.call(data, provider: "openai", model: "gpt-test")
  end

  it "normalizes a confident settlement" do
    result = normalize(extraction_fixture("normal_settlement"))
    document = result["documents"].first

    expect(result["requires_review"]).to be(false)
    expect(document).to include(
      "document_type" => "settlement",
      "total_amount_vnd" => 11_445_000,
      "lot_number" => "000269",
      "transaction_date" => "2026-10-04",
      "transaction_time" => "10:57:25",
      "transaction_at" => "2026-10-04T10:57:25+07:00",
      "merchant_name" => "HỘ KINH DOANH THIÊN KIM GV",
      "low_confidence_fields" => []
    )
  end

  it "flags low-confidence critical fields" do
    document = normalize(extraction_fixture("blurry_settlement"))["documents"].first
    expect(document["requires_review"]).to be(true)
    expect(document["low_confidence_fields"]).to include("total_amount_vnd", "merchant_name", "transaction_time")
  end

  it "keeps every settlement of a multi-settlement image" do
    documents = normalize(extraction_fixture("two_settlements"))["documents"]
    expect(documents.map { |d| d["index"] }).to eq([ 0, 1 ])
    expect(documents.map { |d| d["total_amount_vnd"] }).to eq([ 11_445_000, 5_000_000 ])
  end

  it "parses Vietnamese thousand separators but nothing else" do
    data = { "documents" => [ { "document_type" => "settlement", "total_amount_vnd" => "11.445.000" } ] }
    expect(normalize(data)["documents"].first["total_amount_vnd"]).to eq(11_445_000)

    data["documents"].first["total_amount_vnd"] = "11,4 trieu"
    expect(normalize(data)["documents"].first["total_amount_vnd"]).to be_nil
  end

  it "forces zero confidence on missing values" do
    data = { "documents" => [ { "document_type" => "settlement", "total_amount_vnd" => nil,
                                "confidence" => { "total_amount_vnd" => 0.99 } } ] }
    expect(normalize(data)["documents"].first.dig("confidence", "total_amount_vnd")).to eq(0.0)
  end

  it "rejects impossible dates and times" do
    data = { "documents" => [ { "document_type" => "settlement", "transaction_date" => "2026-02-30",
                                "transaction_time" => "25:61:00" } ] }
    document = normalize(data)["documents"].first
    expect(document["transaction_date"]).to be_nil
    expect(document["transaction_at"]).to be_nil
  end

  it "treats an empty answer as an unknown document needing review" do
    result = normalize({ "documents" => [] })
    expect(result["documents"].size).to eq(1)
    expect(result["documents"].first["document_type"]).to eq("unknown")
    expect(result["requires_review"]).to be(true)
  end

  it "does not require review for a confident child receipt" do
    expect(normalize(extraction_fixture("child_receipt"))["requires_review"]).to be(false)
  end
end

RSpec.describe BillVision::Normalizer, "edge cases" do
  def normalize(data)
    described_class.call(data, provider: "openai", model: "gpt-test")
  end

  it "requires review when settlements had to be dropped" do
    document = extraction_fixture("normal_settlement")["documents"].first
    result = normalize({ "documents" => Array.new(described_class::MAX_DOCUMENTS + 2) { document } })
    expect(result["documents"].size).to eq(described_class::MAX_DOCUMENTS)
    expect(result["documents_truncated"]).to eq(2)
    expect(result["requires_review"]).to be(true)
  end

  it "accepts a merchant identified by a confident MID/TID even if the name is unclear" do
    document = extraction_fixture("normal_settlement")["documents"].first
    document["confidence"] = document["confidence"].merge("merchant_name" => 0.4, "terminal_or_merchant_id" => 0.97)
    result = normalize({ "documents" => [ document ] })
    expect(result["documents"].first["low_confidence_fields"]).to be_empty
  end
end
