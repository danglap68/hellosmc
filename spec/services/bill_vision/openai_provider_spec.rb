require "rails_helper"

RSpec.describe BillVision::OpenaiProvider do
  let(:image) { BillVision::Image.new(bytes: File.binread(bill_fixture_path("normal_settlement.jpg")), mime_type: "image/jpeg") }
  let(:provider) { described_class.new(api_key: "sk-test", model: "gpt-4.1") }
  let(:content) { extraction_fixture("normal_settlement").to_json }

  def stub_openai(status: 200, body: nil)
    body ||= { "id" => "chatcmpl-1", "model" => "gpt-4.1-2025", "choices" => [ { "message" => { "content" => content } } ] }
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  it "sends the image with a strict JSON schema and parses the answer" do
    request = stub_openai
    result = provider.extract(image)

    expect(result.provider).to eq("openai")
    expect(result.model).to eq("gpt-4.1-2025")
    expect(result.data["documents"].first["total_amount_vnd"]).to eq(11_445_000)
    expect(request.with { |req|
      body = JSON.parse(req.body)
      body.dig("response_format", "json_schema", "strict") == true &&
        body["temperature"] == 0 &&
        body.dig("messages", 1, "content", 1, "image_url", "url").start_with?("data:image/jpeg;base64,") &&
        req.headers["Authorization"] == "Bearer sk-test"
    }).to have_been_made
  end

  it "accepts valid receipt facts when optional integrity screening was omitted" do
    data = extraction_fixture("normal_settlement")
    data["documents"].first.delete("image_integrity")
    stub_openai(body: { "choices" => [ { "message" => { "content" => data.to_json } } ] })
    expect(provider.extract(image).data).to eq(data)
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "test")
    expect(normalized["documents"].sole["image_integrity"]["status"]).to eq("not_assessed")
  end

  it "accepts a transfer without image screening while asking incoming receipts for an advisory score" do
    data = extraction_fixture("transfer")
    data["documents"].first["image_integrity"] = nil
    stub_openai(body: { "choices" => [ { "message" => { "content" => data.to_json } } ] })

    expect(provider.extract(image).data["documents"].first["image_integrity"]).to be_nil
    schema = BillVision::Prompt::SCHEMA.dig(:properties, :documents, :items, :properties, :image_integrity)
    expect(schema[:required]).to include("risk_score")
    expect(schema.dig(:properties, :risk_score, :minimum)).to eq(0)
    expect(schema.dig(:properties, :risk_score, :maximum)).to eq(1)
  end

  it "treats rate limits and server errors as transient" do
    stub_openai(status: 429, body: { "error" => "rate limited" })
    expect { provider.extract(image) }.to raise_error(BillVision::TransientError)
  end

  it "sends the configured catalog and accepts a selected ID without replacing the printed name" do
    merchant = create(:merchant, name: "Gat Tan Day Coffe")
    data = extraction_fixture("normal_settlement")
    data["documents"].first.merge!("merchant_name" => "GÁT TÁN DÂY COFFEE 2",
                                   "merchant_match" => { "merchant_id" => merchant.id, "confidence" => 0.96 })
    stub_openai(body: { "choices" => [ { "message" => { "content" => data.to_json } } ] })
    result = provider.extract(image)
    expect(result.data["documents"].first["merchant_name"]).to eq("GÁT TÁN DÂY COFFEE 2")
    expect(result.data["documents"].first.dig("merchant_match", "merchant_id")).to eq(merchant.id)
    expect(a_request(:post, "https://api.openai.com/v1/chat/completions").with { |request|
      text = JSON.parse(request.body).dig("messages", 1, "content", 0, "text")
      JSON.parse(text.split("Configured HKD catalog (JSON data):\n").last).sole ==
        { "id" => merchant.id, "name" => "Gat Tan Day Coffe", "aliases" => [] }
    }).to have_been_made.once
  end

  it "rejects a hallucinated or inactive catalog ID" do
    merchant = create(:merchant, active: false)
    data = extraction_fixture("normal_settlement")
    data["documents"].first["merchant_match"] = { "merchant_id" => merchant.id, "confidence" => 0.99 }
    stub_openai(body: { "choices" => [ { "message" => { "content" => data.to_json } } ] })
    expect { provider.extract(image) }.to raise_error(BillVision::InvalidExtraction, /outside the supplied catalog/)
  end

  it "treats bad requests as permanent" do
    stub_openai(status: 400, body: { "error" => "bad image" })
    expect { provider.extract(image) }.to raise_error(BillVision::PermanentError)
  end

  it "treats refusals and invalid JSON as permanent" do
    stub_openai(body: { "choices" => [ { "message" => { "refusal" => "cannot" } } ] })
    expect { provider.extract(image) }.to raise_error(BillVision::PermanentError, /refused/)

    stub_openai(body: { "choices" => [ { "message" => { "content" => "not json" } } ] })
    expect { provider.extract(image) }.to raise_error(BillVision::PermanentError)
  end

  it "requires an API key" do
    expect { described_class.new(api_key: nil) }.to raise_error(BillVision::PermanentError)
  end

  it "refuses token limits outside the hard envelope before sending a request" do
    [ 0, 4097, "700" ].each do |limit|
      expect { described_class.new(api_key: "test", max_output_tokens: limit) }.to raise_error(BillVision::PermanentError)
    end
  end

  it "retains malformed response envelopes as non-retryable extraction failures" do
    stub_openai(body: { "choices" => "invalid", "usage" => { "total_tokens" => 20 } })
    expect { provider.extract(image) }.to raise_error(BillVision::InvalidExtraction) { |error|
      expect(error.raw.dig("usage", "total_tokens")).to eq(20)
    }
    stub_openai(body: [])
    expect { provider.extract(image) }.to raise_error(BillVision::InvalidExtraction)
  end

  it "does not accept schema drift or non-text message content" do
    invalid = extraction_fixture("normal_settlement").merge("fee" => "AI must not decide this")
    stub_openai(body: { "choices" => [ { "message" => { "content" => invalid.to_json } } ] })
    expect { provider.extract(image) }.to raise_error(BillVision::InvalidExtraction)
    stub_openai(body: { "choices" => [ { "message" => { "content" => [] } } ] })
    expect { provider.extract(image) }.to raise_error(BillVision::InvalidExtraction)
  end
end
