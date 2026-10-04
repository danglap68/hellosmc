module Telegram
  # Admin-side setup of the bot: store a token after Telegram confirms it, and
  # register the production webhook with a freshly generated secret. Secrets
  # go to AppSecret (encrypted); the audit log only records what happened.
  module Connection
    class Error < StandardError; end

    module_function

    # Returns the bot's username.
    def save_token!(token, actor:)
      token = token.to_s.strip
      raise Error, I18n.t("settings.telegram.errors.token_blank") if token.empty?

      bot = BotClient.new(token: token).get_me
      AppSecret.set!("telegram_bot_token", token, actor: actor)
      AuditLogger.log!(actor: actor, action: "telegram.token_updated", metadata: { "bot_username" => bot["username"] })
      bot["username"]
    rescue BotClient::Error => e
      raise Error, I18n.t("settings.telegram.errors.token_rejected", error: e.message)
    end

    # Telegram is updated first so a failed call keeps the current webhook working.
    def register_webhook!(actor:, url: webhook_url)
      raise Error, I18n.t("settings.telegram.errors.app_host_missing") if url.blank?

      secret = SecureRandom.hex(32)
      BotClient.new.set_webhook(url: url, secret_token: secret)
      AppSecret.set!("telegram_webhook_secret", secret, actor: actor)
      AuditLogger.log!(actor: actor, action: "telegram.webhook_registered", metadata: { "url" => url })
      url
    rescue BotClient::Error => e
      raise Error, I18n.t("settings.telegram.errors.webhook_failed", error: e.message)
    end

    def webhook_url
      host = ENV["APP_HOST"].presence
      host && "https://#{host}/webhooks/telegram"
    end
  end
end
