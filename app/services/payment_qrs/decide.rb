module PaymentQrs
  class Decide
    # Consistent lock order with approval/preparation. The original accounting
    # transaction is never modified by a payout correction.
    def self.call(request:, decision:, amount: nil, version:, actor: nil, telegram_user_id: nil)
      request.recorded_transaction.with_lock do
        request.lock!
        TelegramAccess.authorize!(request, user_id: telegram_user_id) if telegram_user_id
        raise Error, "Bill hoặc thông tin nhận tiền đã thay đổi. Hãy làm mới yêu cầu trên admin." unless request.current?
        raise Error, "Quyết định không hợp lệ." unless decision.in?(%w[confirm cancel])

        value = amount.nil? ? request.snapshot.fetch("dealer_amount_vnd").to_s : amount.to_s
        if decision == "confirm" && !value.match?(/\A[1-9]\d{0,12}\z/)
          raise Error, "Nhập số tiền VND nguyên dương, tối đa 13 chữ số (không nhập dấu chấm/phẩy)."
        end
        # A repeated submit returns the same QR without another audit or send.
        return request if (decision == "confirm" && request.confirmed? && request.transfer_amount_vnd == value.to_i) ||
                          (decision == "cancel" && request.cancelled?)
        raise Error, "Yêu cầu đã được xử lý hoặc thay đổi. Hãy tải lại." unless request.pending? && request.lock_version.to_s == version.to_s

        before = request.audit_snapshot
        if decision == "confirm"
          payload = Vietqr.payload(bank_bin: request.snapshot.fetch("bank_bin"),
                                  account_number: request.snapshot.fetch("account_number"),
                                  amount: value, memo: request.snapshot.fetch("transfer_code"))
          request.update!(status: "confirmed", transfer_amount_vnd: value.to_i, qr_payload: payload,
                          confirmed_at: Time.current, confirmed_by: actor, confirmed_by_telegram_id: telegram_user_id)
        else
          request.update!(status: "cancelled")
        end
        AuditLogger.log!(actor: actor, action: "payment_qr.#{decision == 'confirm' ? 'confirmed' : 'cancelled'}",
                         auditable: request, before_data: before, after_data: request.audit_snapshot,
                         metadata: { "telegram_user_id" => telegram_user_id,
                                     "original_amount_vnd" => request.snapshot["dealer_amount_vnd"],
                                     "confirmed_amount_vnd" => request.transfer_amount_vnd }.compact)
        if request.confirmed? && AppSetting.get("payment_qr_telegram_enabled")
          id = request.id
          ActiveRecord.after_all_transactions_commit { DeliverPaymentQrJob.perform_later(id, "qr") }
        end
      end
      request
    rescue ArgumentError => e
      raise Error, e.message
    end
  end
end
