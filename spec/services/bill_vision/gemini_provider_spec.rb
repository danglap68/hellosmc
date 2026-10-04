require "rails_helper"

RSpec.describe BillVision::GeminiProvider do
  let(:image) { BillVision::Image.new(bytes: "fake-bytes", mime_type: "image/png") }

  it "converts the shared schema to Gemini's format" do
    schema = described_class.gemini_schema(BillVision::Prompt::SCHEMA)
    amount = schema.dig("properties", "documents", "items", "properties", "total_amount_vnd")
    expect(amount).to eq("type" => "INTEGER", "nullable" => true)
    expect(schema.to_json).not_to include("additionalProperties")
  end

  it "parses the generated JSON" do
    stub_request(:post, %r{generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent})
      .with(headers: { "x-goog-api-key" => "g-key" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
        "candidates" => [ { "finishReason" => "STOP", "content" => { "parts" => [ { "text" => extraction_fixture("normal_settlement").to_json } ] } } ],
        "modelVersion" => "gemini-test-001"
      }.to_json)

    result = described_class.new(api_key: "g-key", model: "gemini-test").extract(image)
    expect(result.model).to eq("gemini-test-001")
    expect(result.data["documents"].size).to eq(1)
  end
end
