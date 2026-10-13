# Single access point for configuration.
#
# * Business/operational settings come from AppSetting (edited by admins).
# * Secrets of external services come from ENV and are never stored in the DB.
module AppConfig
  module_function

  # --- Client settings (Cài đặt, plain-language switches) -----------------

  # When false, groups the bot is added to are registered inactive and their
  # messages are stored but not processed until an admin activates them.
  def telegram_auto_activate_chats? = AppSetting.get("telegram_auto_activate_chats")

  # Feature flag for remitter transfers ("người đi tiền").
  def remitter_features_enabled? = AppSetting.get("remitter_features_enabled")

  # --- Technical tuning (edited by admins under "Thông số kỹ thuật") -------
  #
  # Each value comes from, in order: the value an admin saved on the settings
  # page (TuningForm), an environment variable on the server, then the
  # default here. Invalid values fall back to the next source and are logged.
  # :range is only enforced when an admin saves; readers clamp on their own.
  TUNING = {
    "vision_provider" => { env: "OCR_PROVIDER", default: "openai", type: :string, options: %w[openai gemini fake] },
    "primary_vision_model" => { env: "OCR_PRIMARY_MODEL", default: "gpt-6-luna", type: :string, legacy: "openai_vision_model" },
    "validator_vision_model" => { env: "OCR_VALIDATOR_MODEL", default: "gpt-6.1-sol", type: :string },
    "vision_validation_enabled" => { env: "OCR_VALIDATION_ENABLED", default: "true", type: :boolean },
    "gemini_vision_model" => { env: "GEMINI_VISION_MODEL", default: "gemini-2.5-flash", type: :string },
    "ocr_auto_approve_threshold" => { env: "OCR_AUTO_APPROVE_THRESHOLD", default: "0.92", type: :rate },
    "ocr_review_threshold" => { env: "OCR_REVIEW_THRESHOLD", default: "0.70", type: :rate },
    "vision_timeout_seconds" => { env: "OCR_TIMEOUT_SECONDS", default: "60", type: :integer, range: 10..300 },
    "max_ocr_attempts" => { env: "OCR_MAX_ATTEMPTS", default: "3", type: :integer, range: 1..3 },
    "merchant_fuzzy_threshold" => { env: "MERCHANT_FUZZY_THRESHOLD", default: "0.88", type: :rate },
    "merchant_auto_accept_score" => { env: "MERCHANT_AUTO_ACCEPT_SCORE", default: "0.90", type: :rate },
    "duplicate_window_minutes" => { env: "DUPLICATE_WINDOW_MINUTES", default: "10", type: :integer, range: 1..1440 },
    "max_receipt_age_days" => { env: "MAX_RECEIPT_AGE_DAYS", default: "45", type: :integer, range: 1..3650 },
    "album_collect_window_seconds" => { env: "ALBUM_COLLECT_WINDOW_SECONDS", default: "15", type: :integer, range: 3..300 },
    "max_bill_image_mb" => { env: "MAX_BILL_IMAGE_MB", default: "20", type: :integer, range: 1..20 },
    "mailer_sender" => { env: "MAILER_SENDER", default: "no-reply@hellosmc.com", type: :string }
  }.freeze

  # [value, source] with source :stored, :env or :default.
  def tuning(key)
    spec = TUNING.fetch(key)
    [ [ stored_tuning(key), :stored ], [ ENV[spec[:env]], :env ] ].each do |raw, source|
      next if raw.blank?

      value = cast_tuning(spec, raw)
      return [ value, source ] unless value.nil?

      Rails.logger.warn("[AppConfig] ignoring invalid #{source} value #{raw.inspect} for #{key}")
    end
    [ cast_tuning(spec, spec[:default]), :default ]
  end

  def tuned(key) = tuning(key).first

  # The admin's saved value, or one saved under the key's old name.
  def stored_tuning(key, stored = AppSetting.stored_values)
    legacy = TUNING.fetch(key)[:legacy]
    stored[key].presence || (legacy && stored[legacy].presence)
  end

  def cast_tuning(spec, raw)
    text = raw.to_s.strip
    value =
      case spec[:type]
      when :integer then Integer(text, 10)
      when :rate then BigDecimal(text).then { |rate| rate.between?(0, 1) ? rate : nil }
      when :boolean then { "true" => true, "1" => true, "false" => false, "0" => false }.fetch(text.downcase, nil)
      else text
      end
    spec[:options] && !spec[:options].include?(value) ? nil : value
  rescue ArgumentError, TypeError
    nil
  end

  def vision_provider = tuned("vision_provider")
  def primary_vision_model = tuned("primary_vision_model")
  def validator_vision_model = tuned("validator_vision_model")
  def vision_validation_enabled? = tuned("vision_validation_enabled")
  # Read again only when a risk was detected (the only mode).
  def vision_validation_mode = "risk_based"
  def gemini_vision_model = tuned("gemini_vision_model")
  def ocr_auto_approve_threshold = tuned("ocr_auto_approve_threshold")
  def ocr_review_threshold = [ tuned("ocr_review_threshold"), ocr_auto_approve_threshold ].min
  def vision_timeout_seconds = tuned("vision_timeout_seconds").clamp(10, 300)
  def max_ocr_attempts = tuned("max_ocr_attempts").clamp(1, BillVision::CallBudget::MAX_OCR_RUNS_PER_BILL)
  def merchant_fuzzy_threshold = tuned("merchant_fuzzy_threshold")
  # A near name match at this score or above is accepted as the HKD (no review of its own).
  def merchant_auto_accept_score = tuned("merchant_auto_accept_score")
  # Possible duplicate: same merchant + amount within this many minutes.
  def duplicate_window_minutes = tuned("duplicate_window_minutes")
  # Receipts older than this are suspicious (wrong year/month read by OCR).
  def max_receipt_age_days = tuned("max_receipt_age_days")
  # How long to wait for more photos of a Telegram album before finalizing it.
  def album_collect_window_seconds = tuned("album_collect_window_seconds").clamp(3, 300)
  # Telegram's bot download limit is 20 MB.
  def max_bill_image_bytes = tuned("max_bill_image_mb").clamp(1, 20).megabytes
  def mailer_sender = tuned("mailer_sender")

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

  # Set under Cài đặt → Kết nối (AppSetting) so a new Google Sheet can be
  # switched to without a deploy; ENV is the fallback.
  def hello_smc_spreadsheet_id
    AppSetting.stored_values["hello_smc_spreadsheet_id"].presence || ENV["HELLO_SMC_SPREADSHEET_ID"].presence
  end

  def google_sheets_credentials_path = ENV["GOOGLE_SHEETS_CREDENTIALS_PATH"].presence
  def google_sheets_credentials_json = ENV["GOOGLE_SHEETS_CREDENTIALS_JSON"].presence
  def google_sheets_configured?
    hello_smc_spreadsheet_id.present? &&
      (google_sheets_credentials_path.present? || google_sheets_credentials_json.present?)
  end

  def active_storage_service
    Rails.configuration.active_storage.service.to_s
  end
end
