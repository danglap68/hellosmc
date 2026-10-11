module RemitterTransfers
  # Decides whether a Telegram photo is a remitter's transfer ("đi tiền") or a
  # settlement bill ("kết toán"). A transfer never becomes a Transaction.
  #
  # Before OCR (on receipt), any of:
  #   * the sender is an active Remitter (Telegram user id, then username)
  #   * the caption carries a known transfer code ("TK01")
  # After OCR, for a photo that was not routed above:
  #   * a single photo (not part of an album) whose documents are bank
  #     transfers and no settlement. Album totals of an agent stay in the
  #     album flow (a transfer total there is reconciled against child bills).
  module Classifier
    module_function

    def remitter_for(sender_id:, username:)
      Remitters::Resolver.call(telegram_user_id: sender_id, telegram_username: username).remitter
    end

    # A known remitter's photo is always a transfer. Anyone else needs the code
    # as a word of its own in the caption (strict), so a settlement caption
    # cannot be taken for a transfer by accident.
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

      types = source.documents.map { |doc| doc["document_type"] }
      types.include?("transfer") && !types.include?("settlement")
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
