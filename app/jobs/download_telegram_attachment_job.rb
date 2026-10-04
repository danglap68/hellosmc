class DownloadTelegramAttachmentJob < ApplicationJob
  queue_as :telegram

  # Permanent problems: wrong file type, oversized file, bad request.
  # Declared before retry_on so that TransientError (a BotClient::Error) is retried.
  rescue_from(Telegram::AttachmentDownloader::InvalidImageError, Telegram::BotClient::Error) do |error|
    mark_failed(error)
  end
  retry_on Telegram::BotClient::TransientError, wait: :polynomially_longer, attempts: 6 do |job, error|
    job.mark_failed(error)
  end

  def perform(telegram_message_id)
    message = TelegramMessage.find(telegram_message_id)
    bill_image = Telegram::AttachmentDownloader.call(message)
    return message.update!(processing_status: "ignored") if bill_image.nil?

    AnalyzeBillImageJob.perform_later(bill_image.id) unless bill_image.ocr_duplicate?
    message.update!(processing_status: "processed") if bill_image.ocr_duplicate?
  end

  def mark_failed(error)
    message = TelegramMessage.find_by(id: arguments.first)
    message&.update!(processing_status: "failed",
                     raw_payload: message.raw_payload.merge("download_error" => error.message.truncate(500)))
    StructuredLog.error("telegram.download_failed", job_id: job_id, telegram_message_record_id: arguments.first,
                                                    error_class: error.class.name, error: error.message.truncate(300))
  end
end
