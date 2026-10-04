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

  it "treats rate limits and server errors as transient" do
    stub_openai(status: 429, body: { "error" => "rate limited" })
    expect { provider.extract(image) }.to raise_error(BillVision::TransientError)
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
end
