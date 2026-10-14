class DeliverPaymentQrJob < ApplicationJob
  queue_as :default

  # Claim before the network call. A timeout leaves delivery uncertain and is
  # never automatically sent again: Telegram has no idempotency key for sends.
  def perform(id, kind)
    return unless kind.in?(%w[summary qr]) && AppSetting.get("payment_qr_telegram_enabled")

    qr = DealerPaymentQr.find(id)
    state = "#{kind}_delivery"
    token = nil
    qr.recorded_transaction.with_lock do
      qr.lock!
      chat = qr.source_chat
      return unless chat&.active? && chat.payment_qr_confirmer_ids.any? && qr.current?
      return unless qr.public_send(state) == "idle" && (kind == "summary" ? qr.pending? : qr.confirmed?)
      return if AppSetting.get("payment_qr_bot_username").blank?

      qr.update!(state => "sending", delivery_error: nil)
      token = qr.access_token
    end

    message = deliver(qr, kind)
    qr.with_lock do
      if qr.access_token == token && qr.public_send(state) == "sending"
        qr.update!(state => "sent", "#{kind}_message_id" => message.fetch("message_id"))
      end
    end
  rescue Telegram::BotClient::Error, Faraday::Error, KeyError => e
    qr&.with_lock do
      if qr.access_token == token && qr.public_send(state) == "sending"
        qr.update!(state => "uncertain", delivery_error: "Chưa xác nhận được Telegram đã nhận. Kiểm tra nhóm trước khi gửi lại.")
      end
    end
    StructuredLog.warn("payment_qr.delivery_uncertain", payment_qr_id: id, kind: kind, error_class: e.class.name)
  end

  private

  def deliver(qr, kind)
    source = qr.recorded_transaction.telegram_message
    params = { chat_id: source.telegram_chat.telegram_chat_id,
               message_thread_id: source.raw_message["message_thread_id"],
               reply_parameters: { message_id: source.telegram_message_id, allow_sending_without_reply: true }.to_json }
    client = Telegram::BotClient.new
    if kind == "summary"
      username = AppSetting.get("payment_qr_bot_username")
      keyboard = { inline_keyboard: [
        [ { text: "Đúng — Tạo QR", callback_data: "pqr:confirm:#{qr.access_token}" } ],
        [ { text: "Sửa số tiền", url: "https://t.me/#{username}?startapp=pqr_#{qr.access_token}&mode=compact" },
         { text: "Hủy", callback_data: "pqr:cancel:#{qr.access_token}" } ]
      ] }
      client.send_message(**params, text: caption(qr, qr.snapshot.fetch("dealer_amount_vnd"), confirmed: false),
                          reply_markup: keyboard.to_json)
    else
      client.send_photo(**params, png: PaymentQrs::Vietqr.png(qr.qr_payload),
                        caption: caption(qr, qr.transfer_amount_vnd, confirmed: true))
    end
  end

  def caption(qr, amount, confirmed:)
    data = qr.snapshot
    money = ActiveSupport::NumberHelper.number_to_delimited(amount, delimiter: ".")
    [ "#{confirmed ? 'QR chuyển khoản' : 'Xác nhận tiền đi'} · Bill ##{qr.transaction_id}",
      "Đại lý: #{data['dealer_name']}", "HKD: #{data['merchant_name']}",
      "Ngân hàng: #{data['bank_name']}", "Tài khoản: #{data['account_number']}",
      "Chủ tài khoản: #{data['account_name']}", "Số tiền: #{money} VND",
      "Nội dung: #{data['transfer_code']}",
      confirmed ? "QR chỉ là yêu cầu chuyển khoản, chưa xác nhận tiền đã được chuyển." : "Kiểm tra thông tin trước khi tạo QR." ].join("\n").truncate(1024)
  end
end
