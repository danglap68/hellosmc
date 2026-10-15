module RemitterTransfers
  # Decides whether a Telegram photo is a remitter's transfer ("đi tiền") or a
  # settlement bill ("kết toán"). A transfer never becomes a Transaction.
  #
  # A known sender or caption code marks a candidate; OCR must then identify
  # a transfer. Agent album totals remain part of their settlement album.
  module Classifier
    module_function

    def remitter_for(sender_id:, username:)
      Remitters::Resolver.call(telegram_user_id: sender_id, telegram_username: username).remitter
    end

    # Sender and strict caption codes identify candidates, not confirmed transfers.
    def transfer_message?(remitter:, text:)
      remitter.present? || CodeMatcher.call(text, strict: true).found?
    end

    # OCR shows a settlement and no transfer.
    def settlement_image?(bill_image)
      types = (bill_image.duplicate_of || bill_image).documents.map { |doc| doc["document_type"] }
      types.include?("settlement") && !types.include?("transfer")
    end

    def transfer_image?(bill_image)
      return false if bill_image.telegram_message.nil? || bill_image.bill_album_id.present?
      source = bill_image.duplicate_of || bill_image
      # A photo that already has transactions (OCR re-run), itself or its
      # original when it is a duplicate, stays a settlement.
      return false if bill_image.transactions.exists? || source.transactions.exists?

      return false if source.documents.any? { |doc| doc["document_type"] == "settlement" }

      # A provider failure or conflicting readings must remain visible for a
      # person, rather than silently losing a potentially genuine transfer.
      if bill_image.telegram_message.remitter_transfer_candidate?
        return true if source.ocr_failed? || source.documents.any? { |doc| BillVision::ImageIntegrity.blocking_reasons(doc["vision_review_reasons"]).any? }
      end

      source.documents.any? do |doc|
        doc["document_type"] == "transfer" ||
          (doc["downgraded_from"] == "transfer" && BillVision::ImageIntegrity.blocking_reasons(doc["vision_review_reasons"]).any?)
      end
    end

    # Turns an already-OCR'd photo into a transfer (sender may be unknown).
    def adopt!(bill_image)
      message = bill_image.telegram_message
      message.remitter_transfer || RemitterTransfer.create!(
        telegram_message: message,
        bill_image: bill_image,
        remitter: remitter_for(sender_id: message.telegram_sender_id, username: message.telegram_username),
        transferred_at: message.sent_at || bill_image.created_at
      )
    rescue ActiveRecord::RecordNotUnique
      message.reload.remitter_transfer
    end
  end
end
