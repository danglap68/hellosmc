module Telegram
  # Thin wrapper around telegram-bot-ruby that returns raw Telegram JSON
  # (so the original payload can be stored) and never leaks the bot token
  # in error messages or logs.
  class BotClient
    class Error < StandardError; end
    class TransientError < Error; end
    class ConflictError < Error; end
    class FileTooLargeError < Error; end

    API_URL = "https://api.telegram.org".freeze
    ALLOWED_UPDATES = %w[message edited_message channel_post edited_channel_post].freeze

    def initialize(token: AppConfig.telegram_bot_token)
      raise Error, "TELEGRAM_BOT_TOKEN is not configured" if token.blank?

      @token = token
      @api = Telegram::Bot::Api.new(token)
    end

    def get_updates(offset:, timeout:)
      call("getUpdates", offset: offset, timeout: timeout, allowed_updates: ALLOWED_UPDATES)
    end

    def get_me
      call("getMe")
    end

    def get_file(file_id)
      call("getFile", file_id: file_id)
    end

    def download_file(file_path, max_bytes:)
      response = file_connection.get("/file/bot#{@token}/#{file_path}")
      raise TransientError, "Telegram file download failed with HTTP #{response.status}" if response.status >= 500
      raise Error, "Telegram file download failed with HTTP #{response.status}" unless response.status == 200

      body = response.body.to_s.b
      raise FileTooLargeError, "Telegram file exceeds #{max_bytes} bytes" if body.bytesize > max_bytes

      body
    rescue Faraday::Error => e
      raise TransientError, scrub(e.message)
    end

    def set_webhook(url:, secret_token: nil)
      call("setWebhook", url: url, secret_token: secret_token, allowed_updates: ALLOWED_UPDATES)
    end

    def delete_webhook
      call("deleteWebhook")
    end

    def webhook_info
      call("getWebhookInfo")
    end

    private

    def call(endpoint, params = {})
      payload = @api.call(endpoint, params.compact)
      raise Error, "Telegram #{endpoint} returned ok=false" unless payload["ok"]

      payload["result"]
    rescue Telegram::Bot::Exceptions::ResponseError => e
      raise ConflictError, scrub(e.message) if e.error_code.to_i == 409
      raise TransientError, scrub(e.message) if e.error_code.to_i == 429 || e.error_code.to_i >= 500

      raise Error, scrub(e.message)
    rescue Faraday::Error => e
      raise TransientError, scrub(e.message)
    end

    def file_connection
      @file_connection ||= Faraday.new(url: API_URL) do |faraday|
        faraday.options.timeout = 60
        faraday.options.open_timeout = 10
      end
    end

    def scrub(message)
      message.to_s.gsub(@token, "[FILTERED]")
    end
  end
end
