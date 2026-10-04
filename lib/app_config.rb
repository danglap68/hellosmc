# Single access point for configuration.
#
# * Business/operational settings come from AppSetting (edited by admins).
# * Secrets of external services come from ENV and are never stored in the DB.
module AppConfig
  module_function

  # --- Admin settings ------------------------------------------------------

  def ocr_auto_approve_threshold = AppSetting.get("ocr_auto_approve_threshold")
  def ocr_review_threshold = AppSetting.get("ocr_review_threshold")
  def vision_provider = AppSetting.get("vision_provider")
  def openai_vision_model = AppSetting.get("openai_vision_model")
  # Preserve an explicitly stored legacy model until the primary setting is
  # saved. Old gpt-4.1 records and existing operator choices remain readable.
  def primary_vision_model
    AppSetting.stored_values["primary_vision_model"].presence ||
      AppSetting.stored_values["openai_vision_model"].presence || AppSetting.get("primary_vision_model")
  end
  def validator_vision_model = AppSetting.get("validator_vision_model")
  def vision_validation_enabled? = AppSetting.get("vision_validation_enabled")
  def vision_validation_mode = AppSetting.get("vision_validation_mode")
  def gemini_vision_model = AppSetting.get("gemini_vision_model")
  def vision_timeout_seconds = AppSetting.get("vision_timeout_seconds")
  def max_ocr_attempts = AppSetting.get("max_ocr_attempts").clamp(1, BillVision::CallBudget::MAX_OCR_RUNS_PER_BILL)
  def merchant_fuzzy_threshold = AppSetting.get("merchant_fuzzy_threshold")
  # Possible duplicate: same merchant + amount within this many minutes.
  def duplicate_window_minutes = AppSetting.get("duplicate_window_minutes")
  # Receipts older than this are suspicious (wrong year/month read by OCR).
  def max_receipt_age_days = AppSetting.get("max_receipt_age_days")
  def mailer_sender = AppSetting.get("mailer_sender")

  # When false, groups the bot is added to are registered inactive and their
  # messages are stored but not processed until an admin activates them.
  def telegram_auto_activate_chats? = AppSetting.get("telegram_auto_activate_chats")

  def max_bill_image_bytes = AppSetting.get("max_bill_image_mb").megabytes

  # --- Secrets (ENV) -------------------------------------------------------

  def openai_api_key = ENV["OPENAI_API_KEY"].presence
  def gemini_api_key = ENV["GEMINI_API_KEY"].presence
  # Set under Cài đặt → Telegram (encrypted in AppSecret); ENV is the fallback.
  def telegram_bot_token = AppSecret.get("telegram_bot_token") || ENV["TELEGRAM_BOT_TOKEN"].presence
  def telegram_webhook_secret = AppSecret.get("telegram_webhook_secret") || ENV["TELEGRAM_WEBHOOK_SECRET"].presence
  R2_ENV = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_ENDPOINT].freeze
  def r2_missing_env = R2_ENV.select { |key| ENV[key].blank? }
  def r2_configured? = r2_missing_env.empty?
  def smtp_configured? = ENV["SMTP_ADDRESS"].present?

  def active_storage_service
    Rails.configuration.active_storage.service.to_s
  end
end
