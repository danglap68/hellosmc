# Safety net for the webhook inbox, run from cron
# (`bin/rails hellosmc:retry_stuck_telegram_updates`).
class RetryStuckTelegramUpdatesJob < ApplicationJob
  queue_as :default

  STALE_AFTER = 5.minutes
  MAX_ATTEMPTS = 5
  RETENTION = 14.days

  def perform
    TelegramUpdate.where(status: %w[received failed])
      .where(updated_at: ..STALE_AFTER.ago)
      .where(attempts: ...MAX_ATTEMPTS)
      .find_each { |row| ProcessTelegramUpdateJob.perform_later(row.id) }

    TelegramUpdate.where(status: "processed").where(processed_at: ..RETENTION.ago).delete_all
  end
end
