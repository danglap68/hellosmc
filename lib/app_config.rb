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
  def gemini_vision_model = AppSetting.get("gemini_vision_model")
  def vision_timeout_seconds = AppSetting.get("vision_timeout_seconds")
  def max_ocr_attempts = AppSetting.get("max_ocr_attempts")
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
  def telegram_bot_token = ENV["TELEGRAM_BOT_TOKEN"].presence
  def telegram_webhook_secret = ENV["TELEGRAM_WEBHOOK_SECRET"].presence
  def r2_configured? = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_ENDPOINT].all? { |key| ENV[key].present? }
  def smtp_configured? = ENV["SMTP_ADDRESS"].present?

  def active_storage_service
    Rails.configuration.active_storage.service.to_s
  end
end
