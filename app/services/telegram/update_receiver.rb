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
      if @update["callback_query"].present?
        update = @update.to_h.deep_stringify_keys
        ActiveRecord.after_all_transactions_commit { ProcessPaymentQrCallbackJob.perform_later(update.fetch("callback_query")) }
        return result(:queued_callback)
      end
      parsed = MessageParser.call(@update)
      return result(:ignored_no_message) unless parsed

      chat = upsert_chat(parsed)
      return handle_edit(chat, parsed) if parsed.edited

      message, created = persist_message(chat, parsed)
      unless created
        log("telegram.update_duplicate", chat, parsed)
        return result(:duplicate, message)
      end

      route_new_message(chat, parsed, message)
    end

    private

    # Same routing as a first delivery. Inactive chats are stored and not
    # downloaded. Only an image of an active chat is queued for OCR.
    def route_new_message(chat, parsed, message)
      # Flag off: no transfer flow at all. Every photo (remitters' included)
      # takes the normal path, so a remitter's settlement bill still becomes a
      # transaction; a transfer photo is dropped after OCR (AnalyzeBillImageJob).
      if parsed.image? && AppConfig.remitter_features_enabled? && transfer_photo?(parsed, chat)
        return receive_remitter_image(chat, parsed, message, remitter_sender(parsed))
      end

      # A remitter's photos are never an agent album (child bills + total):
      # with the flag off each one is judged on its own after OCR (settlement
      # -> transaction, anything else skipped) instead of the album path
      # turning every transfer into a "tổng kết" transaction to reject by hand.
      if parsed.image? && parsed.media_group_id.present? && remitter_sender(parsed).nil?
        BillAlbums::Collector.call(message)
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

    def remitter_sender(parsed)
      return @remitter_sender if defined?(@remitter_sender)

      @remitter_sender = RemitterTransfers::Classifier.remitter_for(sender_id: parsed.sender_id,
                                                                    username: parsed.sender_username)
    end

    # "Đi tiền" vs "kết toán", decided on receipt: a remitter's photo, a caption
    # with a transfer code, or a photo of an album already routed as a transfer
    # (only the first photo of an album carries the caption). Photos that slip
    # through are caught after OCR (AnalyzeBillImageJob).
    def transfer_photo?(parsed, chat)
      return true if RemitterTransfers::Classifier.transfer_message?(remitter: remitter_sender(parsed), text: parsed.text)
      return false if parsed.media_group_id.blank?

      siblings = TelegramMessage.where(telegram_chat: chat, media_group_id: parsed.media_group_id).select(:id)
      TelegramMessage.where(id: siblings).where("raw_payload @> ?::jsonb", { remitter_transfer_candidate: true }.to_json).exists? ||
        RemitterTransfer.where(telegram_message_id: siblings).exists?
    end

    # Sender/caption only identify candidates. Create a transfer after OCR,
    # so calculators and confirmation forms never become accounting records.
    # Albums are not collected: every candidate photo is judged separately.
    def receive_remitter_image(chat, parsed, message, remitter)
      unless chat.active?
        message.update!(processing_status: "ignored")
        log("telegram.chat_inactive", chat, parsed)
        return result(:ignored_inactive_chat, message)
      end

      message.update!(processing_status: "queued",
                      raw_payload: message.raw_payload.merge("remitter_transfer_candidate" => true))
      DownloadTelegramAttachmentJob.perform_later(message.id)
      log("telegram.remitter_transfer_received", chat, parsed, telegram_message_record_id: message.id,
                                                                remitter_id: remitter&.id)
      result(:queued_remitter_transfer, message)
    end

    # The caption carries the transfer code: re-read it while nothing is written
    # yet; once in the sheet, only flag it for a person.
    def refresh_remitter_transfers(message)
      messages =
        if message.media_group_id.present?
          TelegramMessage.where(telegram_chat_id: message.telegram_chat_id, media_group_id: message.media_group_id)
        else
          TelegramMessage.where(id: message.id)
        end
      RemitterTransfer.where(telegram_message_id: messages.select(:id)).find_each do |transfer|
        if transfer.written?
          transfer.update!(metadata: transfer.metadata.merge("caption_edited_after_write" => true))
        elsif !transfer.processing?
          RemitterTransfers::Builder.call(remitter_transfer: transfer)
        end
      end
    end

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
        telegram_username: parsed.sender_username.to_s.delete_prefix("@").downcase.presence,
        media_group_id: parsed.media_group_id,
        message_text: parsed.text,
        sent_at: parsed.sent_at,
        kind: parsed.kind,
        reply_to_message_id: parsed.reply_to_message_id,
        forwarded_from: parsed.forwarded_from,
        raw_payload: @update.to_h.deep_stringify_keys
      )
      [ message, true ]
    rescue ActiveRecord::RecordNotUnique
      [ TelegramMessage.find_by!(telegram_chat: chat, telegram_message_id: parsed.message_id), false ]
    end

    # An edit can arrive before the original. Store it and route it once, the
    # same way a first delivery is routed, so an active chat's photo is still
    # downloaded and a text message is only stored.
    def create_from_edit(chat, parsed)
      message, created = persist_message(chat, parsed)
      return result(:edit_duplicate, message) unless created

      message.update!(edited_at: parsed.edited_at || Time.current)
      AuditLogger.log!(
        action: "telegram_message.created_from_edit", auditable: message,
        after_data: { "message_text" => parsed.text }
      )
      log("telegram.message_created_from_edit", chat, parsed)
      route_new_message(chat, parsed, message)
    end

    # The edited text replaces message_text (the original stays in raw_payload
    # and the audit log), so bills not built yet use it. Bills already built
    # are never re-booked automatically: if the card-type tags changed, they
    # are sent back to a human.
    def handle_edit(chat, parsed)
      message = TelegramMessage.find_by(telegram_chat: chat, telegram_message_id: parsed.message_id)
      return create_from_edit(chat, parsed) unless message

      edits = Array(message.raw_payload["edits"])
      return result(:edit_duplicate, message) if edits.any? { |edit| edit["update_id"] == parsed.update_id }

      previous_text = message.effective_text
      edits << { "update_id" => parsed.update_id, "text" => parsed.text, "received_at" => Time.current.utc.iso8601 }
      message.update!(
        message_text: parsed.text,
        edited_at: parsed.edited_at || Time.current,
        raw_payload: message.raw_payload.merge("edits" => edits)
      )
      AuditLogger.log!(
        action: "telegram_message.edited", auditable: message,
        before_data: { "message_text" => previous_text }, after_data: { "message_text" => parsed.text }
      )

      refresh_remitter_transfers(message)
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
