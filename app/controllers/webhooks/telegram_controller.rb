module Webhooks
  # Production Telegram webhook. Verifies the secret token, stores the raw
  # update, enqueues processing and returns immediately. OCR never runs here.
  # A database error returns 500 so Telegram sends the update again.
  class TelegramController < ActionController::API
    def create
      return head :unauthorized unless authorized?

      update = JSON.parse(request.raw_post)
      return head :bad_request unless update.is_a?(Hash)

      inbox_id = TelegramUpdate.store!(update)
      ProcessTelegramUpdateJob.perform_later(inbox_id) if inbox_id
      head :ok
    rescue JSON::ParserError
      head :bad_request
    rescue ActiveRecord::ActiveRecordError
      head :internal_server_error
    end

    private

    # The secret is mandatory in production and optional elsewhere.
    def authorized?
      secret = AppConfig.telegram_webhook_secret
      if secret.nil?
        Rails.logger.warn("[telegram] webhook secret is not set (Cài đặt → Telegram → Kết nối webhook)") if Rails.env.production?
        return !Rails.env.production?
      end

      provided = request.headers["X-Telegram-Bot-Api-Secret-Token"].to_s
      ActiveSupport::SecurityUtils.secure_compare(provided, secret)
    end
  end
end
