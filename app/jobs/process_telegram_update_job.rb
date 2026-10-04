# Webhook entry point: the controller enqueues the raw update and returns fast.
class ProcessTelegramUpdateJob < ApplicationJob
  queue_as :telegram

  retry_on ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished, wait: :polynomially_longer, attempts: 5

  def perform(update)
    result = Telegram::UpdateReceiver.call(update)
    StructuredLog.info("telegram.update_processed", job_id: job_id, telegram_update_id: update["update_id"],
                                                    status: result.status)
  end
end
