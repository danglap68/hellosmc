# Admin-editable settings: the few switches the client decides (see
# DEFINITIONS). One row per changed key; missing keys use the default.
# Secrets (API keys, tokens) never live here — they stay in ENV.
class AppSetting < ApplicationRecord
  has_paper_trail

  Definition = Data.define(:key, :type, :default, :group, :min, :max, :options, :allow_blank) do
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

  def self.define(key, type, default, group, min: nil, max: nil, options: nil, allow_blank: false)
    Definition.new(key:, type:, default:, group:, min:, max:, options:, allow_blank:)
  end

  # Only the decisions the client makes. Technical tuning is defined in
  # AppConfig::TUNING and also stored here, edited through TuningForm.
  DEFINITIONS = [
    define("telegram_auto_activate_chats", :boolean, "false", "operations"),
    define("remitter_features_enabled", :boolean, "false", "operations")
  ].index_by(&:key).freeze

  GROUPS = DEFINITIONS.values.map(&:group).uniq.freeze

  # Stored here but edited on the Kết nối card (checked before saving), not
  # through the switches form.
  CONNECTION_KEYS = %w[hello_smc_spreadsheet_id].freeze

  # Web and worker processes pick up changes within this delay.
  CACHE_TTL = 30

  belongs_to :updated_by, class_name: "User", optional: true

  validates :key, presence: true, uniqueness: true, inclusion: { in: ->(_setting) { DEFINITIONS.keys + CONNECTION_KEYS + AppConfig::TUNING.keys } }
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
