module Telegram
  # Recover only images that were queued but never downloaded. Failed OCR,
  # ignored chats and already stored images use their existing recovery paths.
  class StuckDownloads
    STALE_AFTER = 5.minutes

    def self.scope
      TelegramMessage.processing_queued.with_image.where.missing(:bill_images)
        .joins(:telegram_chat).where(telegram_chats: { active: true })
        .where("telegram_messages.updated_at < ?", STALE_AFTER.ago)
    end

    def self.call(apply: false)
      return scope.count unless apply

      count = 0
      scope.find_each do |message|
        message.with_lock do
          next unless message.processing_queued? && message.bill_images.empty? && message.telegram_chat.active?

          DownloadTelegramAttachmentJob.perform_later(message.id)
          message.touch
          count += 1
        end
      end
      count
    end
  end
end
