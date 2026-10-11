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

  it "still rejects unknown extra keys" do
    data = extraction_fixture("transfer")
    data["documents"].first["beneficiary"] = "x"
    expect(described_class.valid?(data)).to be(false)
  end

  it "asks providers for recipient_name" do
    properties = BillVision::Prompt::SCHEMA.dig(:properties, :documents, :items)
    expect(properties[:required]).to include("recipient_name")
    expect(properties[:properties]).to have_key(:recipient_name)
  end
end
