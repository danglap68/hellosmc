module BillVision
  # OpenAI Chat Completions with strict JSON-schema structured output.
  class OpenaiProvider < BaseProvider
    DEFAULT_BASE_URL = "https://api.openai.com".freeze

    def initialize(api_key: AppConfig.openai_api_key, model: AppConfig.primary_vision_model,
                   max_output_tokens: CallBudget::MAX_OUTPUT_TOKENS, base_url: DEFAULT_BASE_URL)
      raise PermanentError, "OPENAI_API_KEY is not configured" if api_key.blank?
      unless max_output_tokens.is_a?(Integer) && max_output_tokens.between?(1, CallBudget::MAX_OUTPUT_TOKENS)
        raise PermanentError, "OpenAI output limit must be between 1 and #{CallBudget::MAX_OUTPUT_TOKENS}"
      end

      @api_key = api_key
      @model = model
      @base_url = base_url
      @max_output_tokens = max_output_tokens
    end

    def name
      "openai"
    end

    attr_reader :model

    def extract(image)
      payload = post_json(connection(@base_url), "/v1/chat/completions", request_body(image),
                          headers: { "Authorization" => "Bearer #{@api_key}" })
      unless payload.is_a?(Hash) && payload["choices"].is_a?(Array) &&
          payload["choices"].first.is_a?(Hash) && payload["choices"].first["message"].is_a?(Hash)
        raise InvalidExtraction.new("openai response envelope is invalid", raw: payload, model: model)
      end
      message = payload.dig("choices", 0, "message")
      if message["refusal"].present?
        raise InvalidExtraction.new("openai refused extraction", raw: payload, model: payload["model"] || model,
                                    reason: "primary_refused")
      end
      if payload.dig("choices", 0, "finish_reason") == "length"
        raise InvalidExtraction.new("openai output token limit reached", raw: payload, model: payload["model"] || model,
                                    reason: "primary_output_truncated")
      end

      begin
        raise PermanentError, "openai answer is not text" unless message["content"].is_a?(String)

        data = parse_content(message["content"])
        raise PermanentError, "openai answer does not match the extraction schema" unless OutputSchema.valid?(data)
      rescue PermanentError => e
        raise InvalidExtraction.new(e.message, raw: payload, model: payload["model"] || model)
      end

      Result.new(provider: name, model: payload["model"] || model, data: data,
                 raw: payload.except("system_fingerprint"))
    end

    private

    def request_body(image)
      body = {
        model: model,
        max_completion_tokens: @max_output_tokens,
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
      body[:temperature] = 0 unless model.match?(/\A(o\d|gpt-[56])/)
      # A small factual JSON answer needs no reasoning on Luna; Sol requires
      # at least low. Reasoning shares the same fixed completion-token cap.
      body[:reasoning_effort] = "none" if model.start_with?("gpt-6-luna")
      body[:reasoning_effort] = "low" if model.start_with?("gpt-6.1-sol")
      body
    end
  end
end
