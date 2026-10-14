module PaymentQrs
  module TelegramAccess
    module_function

    def authorize!(request, user_id:)
      raise Error, "Xác nhận qua Telegram đang tắt. Vui lòng kiểm tra trên admin." unless AppSetting.get("payment_qr_telegram_enabled")

      chat = request.source_chat
      raise Error, "Bạn chưa được cấp quyền xác nhận tiền đi trong nhóm này." unless chat&.active? &&
        chat.payment_qr_confirmer_ids.include?(user_id)
      raise Error, "Bill hoặc thông tin nhận tiền đã thay đổi. Hãy làm mới yêu cầu trên admin." unless request.current?

      request
    end
  end
end
