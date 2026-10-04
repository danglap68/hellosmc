module BillVision
  # Google Gemini generateContent with a response schema.
  class GeminiProvider < BaseProvider
    BASE_URL = "https://generativelanguage.googleapis.com".freeze

    def initialize(api_key: AppConfig.gemini_api_key, model: AppConfig.gemini_vision_model)
      raise PermanentError, "GEMINI_API_KEY is not configured" if api_key.blank?

      @api_key = api_key
      @model = model
    end

    def name
      "gemini"
    end

    attr_reader :model

    def extract(image)
      payload = post_json(connection(BASE_URL), "/v1beta/models/#{model}:generateContent", request_body(image),
                          headers: { "x-goog-api-key" => @api_key })
      candidate = payload.dig("candidates", 0) || {}
      if candidate["finishReason"].present? && candidate["finishReason"] != "STOP"
        raise PermanentError, "gemini stopped with #{candidate['finishReason']}"
      end

      text = Array(candidate.dig("content", "parts")).filter_map { |part| part["text"] }.join
      Result.new(provider: name, model: payload["modelVersion"] || model, data: parse_content(text), raw: payload)
    end

    # Converts the JSON schema to Gemini's OpenAPI subset
    # (upper-case types, `nullable` instead of union types, no additionalProperties).
    def self.gemini_schema(schema)
      schema = schema.deep_stringify_keys
      converted = {}
      types = Array(schema["type"])
      converted["type"] = (types - [ "null" ]).first.to_s.upcase if types.any?
      converted["nullable"] = true if types.include?("null")
      converted["enum"] = schema["enum"] if schema["enum"]
      converted["description"] = schema["description"] if schema["description"]
      converted["required"] = schema["required"] if schema["required"]
      converted["items"] = gemini_schema(schema["items"]) if schema["items"]
      if schema["properties"]
        converted["properties"] = schema["properties"].transform_values { |value| gemini_schema(value) }
        converted["propertyOrdering"] = schema["properties"].keys
      end
      converted
    end

    private

    def request_body(image)
      {
        systemInstruction: { parts: [ { text: Prompt::SYSTEM } ] },
        contents: [ {
          role: "user",
          parts: [
            { inline_data: { mime_type: image.mime_type, data: image.base64 } },
            { text: Prompt::USER }
          ]
        } ],
        generationConfig: {
          temperature: 0,
          responseMimeType: "application/json",
          responseSchema: self.class.gemini_schema(Prompt::SCHEMA)
        }
      }
    end
  end
end
