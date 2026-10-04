# Admin-editable settings (thresholds, OCR model, matching, Telegram, uploads,
# email sender). One row per changed key; missing keys use the default.
# Secrets (API keys, tokens) never live here — they stay in ENV.
class AppSetting < ApplicationRecord
  Definition = Data.define(:key, :type, :default, :group, :min, :max, :options) do
    def cast(raw)
      case type
      when :decimal, :percent then BigDecimal(raw.to_s)
      when :integer then Integer(raw.to_s)
      when :boolean then raw.to_s == "true"
      else raw.to_s
      end
    end

    # Canonical string stored in the database.
    def serialize(value)
      case type
      when :decimal, :percent then BigDecimal(value.to_s).to_s("F")
      when :integer then Integer(value.to_s).to_s
      when :boolean then ActiveModel::Type::Boolean.new.cast(value) ? "true" : "false"
      else value.to_s.strip
      end
    end
  end

  def self.define(key, type, default, group, min: nil, max: nil, options: nil)
    Definition.new(key: key, type: type, default: default, group: group, min: min, max: max, options: options)
  end

  VISION_PROVIDERS = (Rails.env.production? ? %w[openai gemini] : %w[openai gemini fake]).freeze

  DEFINITIONS = [
    define("vision_provider", :select, "openai", "ocr", options: VISION_PROVIDERS),
    define("openai_vision_model", :string, "gpt-4.1", "ocr"),
    define("primary_vision_model", :string, "gpt-6-luna", "ocr"),
    define("validator_vision_model", :string, "gpt-6.1-sol", "ocr"),
    define("vision_validation_enabled", :boolean, "true", "ocr"),
    define("vision_validation_mode", :select, "risk_based", "ocr", options: %w[risk_based]),
    define("gemini_vision_model", :string, "gemini-2.5-flash", "ocr"),
    define("ocr_auto_approve_threshold", :percent, "0.92", "ocr", min: "0.5", max: "1"),
    define("ocr_review_threshold", :percent, "0.70", "ocr", min: "0", max: "1"),
    define("vision_timeout_seconds", :integer, "60", "ocr", min: "10", max: "300"),
    define("max_ocr_attempts", :integer, "3", "ocr", min: "1", max: "3"),
    define("merchant_fuzzy_threshold", :percent, "0.88", "matching", min: "0.5", max: "1"),
    define("duplicate_window_minutes", :integer, "10", "matching", min: "0", max: "1440"),
    define("max_receipt_age_days", :integer, "45", "matching", min: "1", max: "366"),
    define("telegram_auto_activate_chats", :boolean, "false", "telegram"),
    define("max_bill_image_mb", :integer, "20", "uploads", min: "1", max: "20"),
    define("mailer_sender", :string, "no-reply@hellosmc.com", "email")
  ].index_by(&:key).freeze

  GROUPS = DEFINITIONS.values.map(&:group).uniq.freeze

  # Web and worker processes pick up changes within this delay.
  CACHE_TTL = 30

  belongs_to :updated_by, class_name: "User", optional: true

  validates :key, presence: true, uniqueness: true, inclusion: { in: DEFINITIONS.keys }
  validates :value, presence: true, unless: -> { DEFINITIONS[key]&.type == :string }

  after_commit { self.class.reset_cache! }

  class << self
    def get(key)
      definition = DEFINITIONS.fetch(key.to_s)
      definition.cast(stored_values.fetch(definition.key, definition.default))
    end

    # Raw stored strings, cached briefly per process.
    def stored_values
      cache = @cache
      return cache[:values] if cache && cache[:expires_at] > monotonic_now

      values = pluck(:key, :value).to_h
      @cache = { values: values, expires_at: monotonic_now + CACHE_TTL }
      values
    rescue ActiveRecord::ActiveRecordError
      # Database not reachable or table not migrated yet: use defaults, don't cache.
      {}
    end

    def reset_cache!
      @cache = nil
    end

    private

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
