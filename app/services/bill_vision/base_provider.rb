module BillVision
  # A provider turns an image into a Result whose data matches Prompt::SCHEMA.
  class BaseProvider
    def name
      raise NotImplementedError
    end

    def model
      raise NotImplementedError
    end

    def extract(_image)
      raise NotImplementedError
    end

    private

    def connection(base_url)
      Faraday.new(url: base_url) do |faraday|
        faraday.options.timeout = AppConfig.vision_timeout_seconds
        faraday.options.open_timeout = 10
        faraday.headers["Content-Type"] = "application/json"
      end
    end

    def post_json(conn, path, body, headers: {})
      response = conn.post(path, body.to_json, headers)
      handle_http_errors(response)
      JSON.parse(response.body)
    rescue Faraday::Error => e
      raise TransientError, "#{name} request failed: #{e.class.name}"
    rescue JSON::ParserError
      raise TransientError, "#{name} returned a non-JSON response"
    end

    def handle_http_errors(response)
      return if response.status.between?(200, 299)

      detail = response.body.to_s.truncate(500)
      if response.status == 429 || response.status >= 500
        raise TransientError, "#{name} HTTP #{response.status}: #{detail}"
      end

      raise PermanentError, "#{name} HTTP #{response.status}: #{detail}"
    end

    def parse_content(text)
      raise PermanentError, "#{name} returned an empty answer" if text.blank?

      data = JSON.parse(text)
      raise PermanentError, "#{name} answer is not a JSON object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise PermanentError, "#{name} answer is not valid JSON"
    end
  end
end
