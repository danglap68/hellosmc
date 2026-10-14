require "rails_helper"

RSpec.describe BillVision::OutputSchema do
  it "accepts a document with or without recipient_name" do
    expect(described_class.valid?(extraction_fixture("transfer"))).to be(true)
    expect(described_class.valid?(extraction_fixture("transfer_with_recipient"))).to be(true)
  end

  it "rejects a non-string recipient_name" do
    data = extraction_fixture("transfer_with_recipient")
    data["documents"].first["recipient_name"] = 123
    expect(described_class.valid?(data)).to be(false)
  end

  it "accepts the QR and success flags as true, false or null, and nothing else" do
    data = extraction_fixture("transfer")
    [ [ true, false ], [ false, true ], [ nil, nil ] ].each do |success, qr|
      data["documents"].first.merge!("shows_success_message" => success, "shows_qr_code" => qr)
      expect(described_class.valid?(data)).to be(true)
    end

    data["documents"].first["shows_qr_code"] = "yes"
    expect(described_class.valid?(data)).to be(false)
  end

  it "accepts the SMART POS flag as true, false or null, and nothing else" do
    data = extraction_fixture("normal_settlement")
    [ true, false, nil ].each do |value|
      data["documents"].first["shows_smart_pos"] = value
      expect(described_class.valid?(data)).to be(true)
    end

    data["documents"].first["shows_smart_pos"] = "yes"
    expect(described_class.valid?(data)).to be(false)
  end

  it "accepts the bank brand as a string or null, and nothing else" do
    data = extraction_fixture("normal_settlement")
    [ "MBV", nil ].each do |value|
      data["documents"].first["bill_bank_name"] = value
      expect(described_class.valid?(data)).to be(true)
    end

    data["documents"].first["bill_bank_name"] = 5
    expect(described_class.valid?(data)).to be(false)
  end

  it "still rejects unknown extra keys" do
    data = extraction_fixture("transfer")
    data["documents"].first["beneficiary"] = "x"
    expect(described_class.valid?(data)).to be(false)
  end

  it "accepts only a nullable catalog match with an integer ID and bounded confidence" do
    data = extraction_fixture("normal_settlement")
    data["documents"].first["merchant_match"] = { "merchant_id" => 7, "confidence" => 0.97 }
    expect(described_class.valid?(data)).to be(true)
    [ { "merchant_id" => "7", "confidence" => 0.97 },
      { "merchant_id" => 7, "confidence" => 1.1 },
      { "merchant_id" => 7 },
      { "merchant_id" => 7, "confidence" => 0.97, "dealer_id" => 3 } ].each do |match|
      data["documents"].first["merchant_match"] = match
      expect(described_class.valid?(data)).to be(false)
    end
    data["documents"].first["merchant_match"] = nil
    expect(described_class.valid?(data)).to be(true)
  end

  it "asks providers for recipient_name" do
    properties = BillVision::Prompt::SCHEMA.dig(:properties, :documents, :items)
    expect(properties[:required]).to include("recipient_name")
    expect(properties[:properties]).to have_key(:recipient_name)
  end
end
