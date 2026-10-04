module BillVision
  # OpenAI Chat Completions with strict JSON-schema structured output.
  class OpenaiProvider < BaseProvider
    DEFAULT_BASE_URL = "https://api.openai.com".freeze

    def initialize(api_key: AppConfig.openai_api_key, model: AppConfig.openai_vision_model, base_url: DEFAULT_BASE_URL)
      raise PermanentError, "OPENAI_API_KEY is not configured" if api_key.blank?

      @api_key = api_key
      @model = model
      @base_url = base_url
    end

    def name
      "openai"
    end

    attr_reader :model

    def extract(image)
      payload = post_json(connection(@base_url), "/v1/chat/completions", request_body(image),
                          headers: { "Authorization" => "Bearer #{@api_key}" })
      message = payload.dig("choices", 0, "message") || {}
      raise PermanentError, "openai refused: #{message['refusal']}" if message["refusal"].present?

      Result.new(provider: name, model: payload["model"] || model, data: parse_content(message["content"]),
                 raw: payload.except("system_fingerprint"))
    end

    private

    def request_body(image)
      body = {
        model: model,
        messages: [
          { role: "system", content: Prompt::SYSTEM },
          { role: "user", content: [
            { type: "text", text: Prompt::USER },
            { type: "image_url", image_url: { url: image.data_url, detail: "high" } }
          ] }
        ],
        response_format: {
          type: "json_schema",
          json_schema: { name: "settlement_receipt_extraction", strict: true, schema: Prompt::SCHEMA }
        }
      }
      # Reasoning models only accept the default temperature.
      body[:temperature] = 0 unless model.match?(/\A(o\d|gpt-5)/)
      body
    end
  end
end
