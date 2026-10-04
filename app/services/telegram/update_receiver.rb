module Telegram
  # Entry point for every Telegram update, from polling or webhook.
  #
  # Responsibilities are deliberately narrow: normalize the update, persist the
  # source message idempotently and enqueue the download. No accounting logic.
  class UpdateReceiver
    Result = Data.define(:status, :telegram_message)

    def self.call(update)
      new(update).call
    end

    def initialize(update)
      @update = update
    end

    def call
      parsed = MessageParser.call(@update)
      return result(:ignored_no_message) unless parsed

      chat = upsert_chat(parsed)
      return handle_edit(chat, parsed) if parsed.edited
      return result(:ignored_inactive_chat) if !chat.active? && !parsed.image?

      message, created = persist_message(chat, parsed)
      unless created
        log("telegram.update_duplicate", chat, parsed)
        return result(:duplicate, message)
      end

      if !chat.active?
        message.update!(processing_status: "ignored")
        log("telegram.chat_inactive", chat, parsed)
        result(:ignored_inactive_chat, message)
      elsif !parsed.image?
        message.update!(processing_status: "ignored")
        result(:stored_text, message)
      else
        message.update!(processing_status: "queued")
        DownloadTelegramAttachmentJob.perform_later(message.id)
        log("telegram.update_received", chat, parsed, telegram_message_record_id: message.id)
        result(:queued, message)
      end
    end

    private

    def upsert_chat(parsed)
      chat = TelegramChat.find_by(telegram_chat_id: parsed.chat_id)
      chat ||= begin
        TelegramChat.create!(
          telegram_chat_id: parsed.chat_id,
          name: parsed.chat_title,
          chat_type: parsed.chat_type,
          active: AppConfig.telegram_auto_activate_chats?
        )
      rescue ActiveRecord::RecordNotUnique
        TelegramChat.find_by!(telegram_chat_id: parsed.chat_id)
      end

      if parsed.chat_title.present? && chat.name != parsed.chat_title
        chat.update!(name: parsed.chat_title)
      end
      chat
    end

    def persist_message(chat, parsed)
      existing = TelegramMessage.find_by(telegram_chat: chat, telegram_message_id: parsed.message_id)
      return [ existing, false ] if existing

      message = TelegramMessage.create!(
        telegram_chat: chat,
        telegram_message_id: parsed.message_id,
        telegram_update_id: parsed.update_id,
        telegram_sender_id: parsed.sender_id,
        sender_name: parsed.sender_name,
        media_group_id: parsed.media_group_id,
        message_text: parsed.text,
        sent_at: parsed.sent_at,
        raw_payload: @update.to_h.deep_stringify_keys
      )
      [ message, true ]
    rescue ActiveRecord::RecordNotUnique
      [ TelegramMessage.find_by!(telegram_chat: chat, telegram_message_id: parsed.message_id), false ]
    end

    # The edited text replaces message_text (the original stays in raw_payload
    # and the audit log), so bills not built yet use it. Bills already built
    # are never re-booked automatically: if the card-type tags changed, they
    # are sent back to a human.
    def handle_edit(chat, parsed)
      message = TelegramMessage.find_by(telegram_chat: chat, telegram_message_id: parsed.message_id)
      return result(:ignored_edit_unknown_message) unless message

      edits = Array(message.raw_payload["edits"])
      return result(:edit_duplicate, message) if edits.any? { |edit| edit["update_id"] == parsed.update_id }

      previous_text = message.effective_text
      edits << { "update_id" => parsed.update_id, "text" => parsed.text, "received_at" => Time.current.utc.iso8601 }
      message.update!(message_text: parsed.text, raw_payload: message.raw_payload.merge("edits" => edits))
      AuditLogger.log!(
        action: "telegram_message.edited", auditable: message,
        before_data: { "message_text" => previous_text }, after_data: { "message_text" => parsed.text }
      )

      if CardTypeParser.call(previous_text).sort != CardTypeParser.call(message.effective_text).sort
        Transactions::Flagger.call(transactions: message.related_transactions, reason: "caption_edited")
      end
      log("telegram.message_edited", chat, parsed)
      result(:edit_recorded, message)
    end

    def result(status, message = nil)
      Result.new(status: status, telegram_message: message)
    end

    def log(event, chat, parsed, **extra)
      StructuredLog.info(event, telegram_chat_id: chat.telegram_chat_id, telegram_message_id: parsed.message_id,
                                telegram_update_id: parsed.update_id, **extra)
    end
  end
end
