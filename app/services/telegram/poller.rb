module Telegram
  # Local-development long polling loop (bin/telegram_bot).
  # Each update goes through Telegram::UpdateReceiver, exactly like the webhook.
  class Poller
    POLL_TIMEOUT = 25

    def initialize(client: BotClient.new, logger: Rails.logger)
      @client = client
      @logger = logger
      @offset = 0
      @running = false
    end

    def run
      @running = true
      trap_signals
      me = @client.get_me
      @logger.info("[telegram] polling as @#{me['username']} (Ctrl+C to stop)")

      while @running
        poll_once
      end
      @logger.info("[telegram] poller stopped")
    rescue BotClient::ConflictError
      @logger.error("[telegram] a webhook is registered for this bot. Run `bin/rails telegram:delete_webhook` " \
                    "before polling (production uses the webhook, not the poller).")
      raise
    end

    def stop
      @running = false
    end

    def poll_once
      updates = @client.get_updates(offset: @offset, timeout: POLL_TIMEOUT)
      updates.each do |update|
        @offset = update["update_id"].to_i + 1
        handle(update)
      end
    rescue BotClient::TransientError => e
      @logger.warn("[telegram] transient error: #{e.message}; retrying")
      sleep 2 if @running
    end

    private

    # A malformed update must never take the poller down.
    def handle(update)
      UpdateReceiver.call(update)
    rescue StandardError => e
      StructuredLog.error("telegram.update_failed", telegram_update_id: update["update_id"],
                                                    error_class: e.class.name, error: e.message)
    end

    def trap_signals
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @running = false }
      end
    end
  end
end
