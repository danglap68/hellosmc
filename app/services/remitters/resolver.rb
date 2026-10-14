module Remitters
  class Resolver
    Result = Data.define(:remitter, :source)

    def self.call(telegram_user_id: nil, telegram_username: nil)
      new(telegram_user_id:, telegram_username:).call
    end

    def initialize(telegram_user_id:, telegram_username:)
      @telegram_user_id = telegram_user_id.presence&.to_i
      @telegram_username = telegram_username.to_s.strip.delete_prefix("@").downcase.presence
    end

    def call
      if @telegram_user_id && (remitter = Remitter.active.find_by(telegram_user_id: @telegram_user_id))
        return Result.new(remitter:, source: "telegram_user_id")
      end
      # Usernames can change owners. Never use one to override a pinned ID,
      # even when the incoming message has no ID at all.
      if @telegram_username && (remitter = Remitter.active.where(telegram_user_id: nil).find_by(telegram_username: @telegram_username))
        return Result.new(remitter:, source: "telegram_username")
      end

      Result.new(remitter: nil, source: nil)
    end
  end
end
