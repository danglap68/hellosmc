module Webhooks
  # Production Telegram webhook. Verifies the secret
  # token, enqueues the raw update and returns immediately; OCR never runs in
  # the request.
  class TelegramController < ActionController::API
    def create
      return head :unauthorized unless authorized?

      update = JSON.parse(request.raw_post)
      return head :bad_request unless update.is_a?(Hash)

      ProcessTelegramUpdateJob.perform_later(update)
      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    # The secret is mandatory in production and optional elsewhere.
    def authorized?
      secret = AppConfig.telegram_webhook_secret
      if secret.nil?
        Rails.logger.warn("[telegram] TELEGRAM_WEBHOOK_SECRET is not set") if Rails.env.production?
        return !Rails.env.production?
      end

      provided = request.headers["X-Telegram-Bot-Api-Secret-Token"].to_s
      ActiveSupport::SecurityUtils.secure_compare(provided, secret)
    end
  end
end
