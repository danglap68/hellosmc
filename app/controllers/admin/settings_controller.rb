module Admin
  # Business/operational settings (stored in the database, audited).
  # API keys stay in ENV and the page only shows whether they are set; the
  # Telegram bot token and webhook secret are managed here, encrypted (AppSecret).
  class SettingsController < BaseController
    permission :settings

    before_action :load_sidebar, only: %i[show update]

    def show
      @form = SettingsForm.new
    end

    def update
      @form = SettingsForm.new(params.fetch(:settings, {}).permit(*AppSetting::DEFINITIONS.keys))
      if @form.save(actor: current_user)
        redirect_to admin_settings_path, notice: t("settings.flash.saved")
      else
        render :show, status: :unprocessable_content
      end
    end

    # Writes, reads and deletes a test object to prove the R2_* credentials work.
    def check_r2
      result = R2Check.call
      if result.ok?
        redirect_to admin_settings_path, notice: t("settings.r2_check.ok", ms: result.duration_ms)
      else
        redirect_to admin_settings_path, alert: r2_failure_message(result.failure)
      end
    end

    # Stores the bot token once Telegram accepts it. On the production server
    # the webhook is registered right away, so a new bot starts receiving.
    def telegram_token
      username = Telegram::Connection.save_token!(params[:telegram_bot_token], actor: current_user)
      messages = [ t("settings.telegram.token_saved", bot: username) ]
      if Rails.env.production?
        messages << t("settings.telegram.webhook_registered", url: Telegram::Connection.register_webhook!(actor: current_user))
      end
      redirect_to admin_settings_path, notice: messages.join(" ")
    rescue Telegram::Connection::Error => e
      saved = t("settings.telegram.token_saved", bot: username) if username
      redirect_to admin_settings_path, alert: [ saved, e.message ].compact.join(" ")
    end

    def telegram_webhook
      url = Telegram::Connection.register_webhook!(actor: current_user)
      redirect_to admin_settings_path, notice: t("settings.telegram.webhook_registered", url: url)
    rescue Telegram::Connection::Error => e
      redirect_to admin_settings_path, alert: e.message
    end

    private

    # :settings when stored under Cài đặt, :env when only the environment has it.
    def secret_source(key, env)
      if AppSecret.get(key)
        :settings
      elsif ENV[env].present?
        :env
      end
    end

    def r2_failure_message(step)
      hint = step.hint && t("settings.r2_check.hints.#{step.hint}", keys: step.error.message)
      t("settings.r2_check.failed", step: t("settings.r2_check.steps.#{step.name}"), hint: hint,
                                    error: "#{step.error.class.name}: #{step.error.message.truncate(300)}").squish
    end

    def load_sidebar
      @telegram = {
        token: secret_source("telegram_bot_token", "TELEGRAM_BOT_TOKEN"),
        webhook: secret_source("telegram_webhook_secret", "TELEGRAM_WEBHOOK_SECRET"),
        webhook_url: Telegram::Connection.webhook_url
      }
      @services = {
        openai: AppConfig.openai_api_key.present?,
        gemini: AppConfig.gemini_api_key.present?,
        r2: AppConfig.r2_configured?,
        smtp: AppConfig.smtp_configured?
      }
      @storage_service = AppConfig.active_storage_service
      @card_types = CardType.ordered
      @last_change = AuditLog.where(action: "settings.updated").includes(:actor_user).recent_first.first
    end
  end
end
