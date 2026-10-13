# Webhook entry point. A raw Hash is the previous delivery (still in the queue
# during deploy). An id is a row in telegram_updates.
class ProcessTelegramUpdateJob < ApplicationJob
  queue_as :telegram

  retry_on ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished, wait: :polynomially_longer, attempts: 5

  def perform(update)
    if update.is_a?(Hash)
      process_payload(update)
    else
      process_inbox(update)
    end
  end

  private

  def process_payload(update)
    result = Telegram::UpdateReceiver.call(update)
    StructuredLog.info("telegram.update_processed", job_id: job_id, telegram_update_id: update["update_id"],
                                                    status: result.status)
  end

  def process_inbox(id)
    record = TelegramUpdate.find_by(id: id)
    return unless record

    record.with_lock do
      return if record.reload.processed?

      result = Telegram::UpdateReceiver.call(record.payload)
      record.update!(status: "processed", processed_at: Time.current)
      StructuredLog.info("telegram.update_processed", job_id: job_id, telegram_update_id: record.update_id,
                                                      status: result.status)
    end
  rescue StandardError
    mark_failed(id)
    raise
  end

  def mark_failed(id)
    TelegramUpdate.where(id: id).where.not(status: "processed").update_all(
      [ "status = ?, attempts = attempts + 1, updated_at = ?", "failed", Time.current ]
    )
  rescue StandardError
    nil
  end
end
