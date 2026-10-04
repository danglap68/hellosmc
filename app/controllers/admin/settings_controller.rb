module Admin
  # Business/operational settings (stored in the database, audited).
  # Secrets stay in ENV; this page only shows whether they are configured.
  class SettingsController < BaseController
    permission :settings

    before_action :load_sidebar

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

    private

    def load_sidebar
      @services = {
        telegram_bot: AppConfig.telegram_bot_token.present?,
        telegram_webhook_secret: AppConfig.telegram_webhook_secret.present?,
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
