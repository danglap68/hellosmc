class ProcessPaymentQrCallbackJob < ApplicationJob
  queue_as :default

  def perform(callback)
    match = callback["data"].to_s.match(/\Apqr:(confirm|cancel):([a-zA-Z0-9_-]{32})\z/)
    return unless match

    qr = DealerPaymentQr.find_by!(access_token: match[2])
    user_id = callback.dig("from", "id")
    PaymentQrs::TelegramAccess.authorize!(qr, user_id: user_id)
    unless qr.summary_message_id.present? && callback.dig("message", "message_id") == qr.summary_message_id &&
           callback.dig("message", "chat", "id") == qr.source_chat.telegram_chat_id
      raise PaymentQrs::Error, "Nút xác nhận không thuộc tin nhắn gốc."
    end
    PaymentQrs::Decide.call(request: qr, decision: match[1], version: qr.lock_version, telegram_user_id: user_id)
    answer(callback, match[1] == "confirm" ? "Đã xác nhận. QR sẽ được gửi trong nhóm." : "Đã hủy yêu cầu tạo QR.")
  rescue PaymentQrs::Error, ActiveRecord::RecordNotFound => e
    answer(callback, e.is_a?(ActiveRecord::RecordNotFound) ? "Yêu cầu đã được làm mới. Vui lòng dùng tin nhắn mới." : e.message)
  end

  private

  def answer(callback, message)
    Telegram::BotClient.new.answer_callback_query(id: callback.fetch("id"), text: message)
  rescue Telegram::BotClient::Error
    # Callback acknowledgements expire quickly. A failed ack must not repeat
    # the financial decision or enqueue a second QR.
    StructuredLog.warn("payment_qr.callback_ack_failed")
  end
end
