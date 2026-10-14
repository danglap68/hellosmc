require "rails_helper"

RSpec.describe BillVision::Normalizer do
  def normalize(data)
    described_class.call(data, provider: "openai", model: "gpt-test")
  end

  describe "the bank brand" do
    it "is kept, trimmed, on any document and null when absent" do
      data = extraction_fixture("normal_settlement")
      data["documents"].first["bill_bank_name"] = "  MBV "
      expect(normalize(data)["documents"].first["bill_bank_name"]).to eq("MBV")

      data["documents"].first.delete("bill_bank_name")
      expect(normalize(data)["documents"].first["bill_bank_name"]).to be_nil
    end
  end

  describe "a transfer that is not a confirmed transfer" do
    def transfer(**flags)
      data = extraction_fixture("transfer")
      data["documents"].first.merge!(flags.stringify_keys)
      normalize(data)["documents"].first
    end

    it "keeps a transfer that says it succeeded and shows no QR code" do
      expect(transfer(shows_success_message: true, shows_qr_code: false)).to include(
        "document_type" => "transfer", "downgraded_from" => nil, "shows_success_message" => true
      )
    end

    it "becomes unknown (skipped) when the image shows a QR code" do
      document = transfer(shows_success_message: true, shows_qr_code: true)

      expect(document).to include("document_type" => "unknown", "downgraded_from" => "transfer", "shows_qr_code" => true)
    end

    it "becomes unknown (skipped) when no success wording is printed" do
      expect(transfer(shows_success_message: false, shows_qr_code: false)).to include(
        "document_type" => "unknown", "downgraded_from" => "transfer"
      )
    end

    it "keeps its type when the run does not report the flags (older output, null)" do
      expect(transfer["document_type"]).to eq("transfer")
      expect(transfer(shows_success_message: nil, shows_qr_code: nil)["document_type"]).to eq("transfer")
    end

    it "never touches a settlement, whatever the flags say" do
      data = extraction_fixture("normal_settlement")
      data["documents"].first.merge!("shows_qr_code" => true, "shows_success_message" => false)

      expect(normalize(data)["documents"].first["document_type"]).to eq("settlement")
    end
  end

  it "preserves the catalog suggestion separately without changing receipt facts or OCR confidence" do
    data = extraction_fixture("normal_settlement")
    data["documents"].first.merge!("merchant_name" => "GÁT TÁN DÂY COFFEE 2",
                                   "merchant_match" => { "merchant_id" => 7, "confidence" => 0.99 })
    data["documents"].first["confidence"]["merchant_name"] = 0.5
    document = normalize(data)["documents"].sole
    expect(document["merchant_name"]).to eq("GÁT TÁN DÂY COFFEE 2")
    expect(document["merchant_match"]).to eq("merchant_id" => 7, "confidence" => 0.99)
    expect(document.dig("confidence", "merchant_name")).to eq(0.5)
  end

  it "does not assign a catalog HKD to a bank transfer" do
    data = extraction_fixture("transfer")
    data["documents"].first["merchant_match"] = { "merchant_id" => 7, "confidence" => 0.99 }
    expect(normalize(data)["documents"].sole["merchant_match"]).to be_nil
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
      "merchant_name" => "HỘ KINH DOANH THIÊN KIM GV-1",
      "low_confidence_fields" => []
    )
  end

  it "keeps the receiving account holder of a bank transfer" do
    document = normalize(extraction_fixture("transfer_with_recipient"))["documents"].first
    expect(document["document_type"]).to eq("transfer")
    expect(document["recipient_name"]).to eq("TRAN NGUYEN KHANH SON")
    expect(document["requires_review"]).to be(false)
  end

  it "drops a recipient read from anything but a transfer and tolerates runs without the field" do
    data = extraction_fixture("normal_settlement")
    data["documents"].first["recipient_name"] = "TRAN NGUYEN KHANH SON"
    expect(normalize(data)["documents"].first["recipient_name"]).to be_nil
    expect(normalize(extraction_fixture("transfer"))["documents"].first["recipient_name"]).to be_nil
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

  it "normalizes a transfer without requiring merchant or time" do
    document = normalize(extraction_fixture("transfer"))["documents"].first

    expect(document["document_type"]).to eq("transfer")
    expect(document["total_amount_vnd"]).to eq(600_000_000)
    expect(document["merchant_name"]).to be_nil
    expect(document["requires_review"]).to be(false)
    expect(document["low_confidence_fields"]).to be_empty
  end

  it "requires review for a transfer missing its amount" do
    data = { "documents" => [ { "document_type" => "transfer", "total_amount_vnd" => nil,
                                "transaction_date" => "2026-10-04" } ] }
    document = normalize(data)["documents"].first
    expect(document["requires_review"]).to be(true)
    expect(document["low_confidence_fields"]).to include("total_amount_vnd")
  end

  it "reclassifies a transfer carrying POS batch/terminal fields as a child receipt" do
    data = { "documents" => [ { "document_type" => "transfer", "total_amount_vnd" => 20_001_000,
                                "lot_number" => "000078", "terminal_or_merchant_id" => "**** 0957",
                                "merchant_name" => "001_ HỘ KINH DOANH THIÊN KIM",
                                "transaction_date" => "2026-10-05", "transaction_time" => "18:33:32" } ] }
    document = normalize(data)["documents"].first
    expect(document["document_type"]).to eq("child_receipt")
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
