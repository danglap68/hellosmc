require "rails_helper"

RSpec.describe PaymentQrs::RecipientNameReader do
  let(:image) { BillVision::Image.new(bytes: "fake-image-bytes", mime_type: "image/png") }

  def stub_name(data = { account_name: "NGUYEN VAN AN", account_number: "0011001932418", confidence: 0.99 }, finish: "stop", refusal: nil)
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(body: { choices: [ { finish_reason: finish, message: { content: data.to_json, refusal: refusal } } ] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  it "reads a clear name associated with the same account, with one bounded structured request" do
    request = stub_name
    expect(described_class.call(image: image, account_number: "0011001932418")).to eq("NGUYEN VAN AN")
    expect(request).to have_been_requested.once
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").with { |http|
      body = JSON.parse(http.body)
      body["max_completion_tokens"] == 1024 && body.dig("response_format", "json_schema", "strict") == true &&
        !http.body.include?("0011001932418")
    }
  end

  it "does not guess names from mismatched accounts, missing text or low confidence" do
    [ { account_name: "OTHER PERSON", account_number: "999999", confidence: 1 },
      { account_name: "NGUYEN VAN AN", account_number: nil, confidence: 0.99 },
      { account_name: "NGUYEN VAN AN", account_number: "0011001932418", confidence: 0.7 },
      { account_name: nil, account_number: "0011001932418", confidence: 1 } ].each do |data|
      stub_name(data)
      expect(described_class.call(image: image, account_number: "0011001932418")).to be_nil
    end
  end

  it "rejects refusal, truncated output, schema drift and malformed envelopes" do
    [ { finish: "length" }, { refusal: "no" } ].each do |options|
      stub_name(**options)
      expect { described_class.call(image: image, account_number: "0011001932418") }.to raise_error(BillVision::PermanentError)
    end
    stub_name({ account_name: "A", account_number: "0011001932418", confidence: "0.99" })
    expect { described_class.call(image: image, account_number: "0011001932418") }.to raise_error(BillVision::PermanentError)
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(body: { choices: "bad" }.to_json)
    expect { described_class.call(image: image, account_number: "0011001932418") }.to raise_error(BillVision::PermanentError)
  end

  it "supports the configured Gemini reader without using the OpenAI endpoint" do
    AppSetting.create!(key: "vision_provider", value: "gemini")
    ENV["GEMINI_API_KEY"] = "gemini-test"
    data = { account_name: "NGUYEN VAN AN", account_number: "0011001932418", confidence: 0.99 }
    request = stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/models/#{AppConfig.gemini_vision_model}:generateContent")
      .to_return(body: { candidates: [ { finishReason: "STOP", content: { parts: [ { text: data.to_json } ] } } ] }.to_json)
    expect(described_class.call(image: image, account_number: "0011001932418")).to eq("NGUYEN VAN AN")
    expect(request).to have_been_requested.once
    expect(WebMock).not_to have_requested(:post, "https://api.openai.com/v1/chat/completions")
  end
end
