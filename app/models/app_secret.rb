# Secrets admins manage in the UI (Cài đặt → Telegram), encrypted at rest.
# Values are never rendered or written to the audit log. AppConfig falls back
# to ENV when a secret is not stored here.
class AppSecret < ApplicationRecord
  KEYS = %w[telegram_bot_token telegram_webhook_secret].freeze

  belongs_to :updated_by, class_name: "User", optional: true

  encrypts :value

  validates :key, presence: true, uniqueness: true, inclusion: { in: KEYS }
  validates :value, presence: true

  after_commit { self.class.reset_cache! }

  class << self
    def get(key)
      raise ArgumentError, "Unknown secret: #{key}" unless KEYS.include?(key.to_s)

      stored_values[key.to_s]
    end

    def set!(key, value, actor: nil)
      find_or_initialize_by(key: key.to_s).update!(value: value, updated_by: actor)
    end

    # Decrypted values, cached briefly per process like AppSetting.
    def stored_values
      cache = @cache
      return cache[:values] if cache && cache[:expires_at] > monotonic_now

      values = all.each_with_object({}) do |secret, memo|
        memo[secret.key] = secret.value
      rescue ActiveRecord::Encryption::Errors::Decryption
        StructuredLog.error("app_secret.undecryptable", key: secret.key)
      end
      @cache = { values: values, expires_at: monotonic_now + AppSetting::CACHE_TTL }
      values
    rescue ActiveRecord::ActiveRecordError
      # Database not reachable or table not migrated yet: no stored secrets, don't cache.
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
