module PaymentQrs
  class Prepare
    def self.call(transaction, actor: nil, refresh: false)
      request = nil
      transaction.with_lock do
        raise Error, "Chỉ tạo yêu cầu cho bill đã duyệt." unless transaction.approved?

        request = DealerPaymentQr.find_by(transaction_id: transaction.id)
        return request if request && !refresh
        if request && [ request.summary_delivery, request.qr_delivery ].include?("sending")
          raise Error, "Đang gửi Telegram. Chờ gửi xong trước khi làm mới yêu cầu."
        end

        before = request&.audit_snapshot
        request ||= DealerPaymentQr.new(recorded_transaction: transaction)
        snapshot, issue = begin
          [ Snapshot.call(transaction), nil ]
        rescue Error => e
          [ {}, e.message ]
        end
        request.update!(dealer: transaction.dealer, merchant_dealer_id: snapshot["merchant_dealer_id"],
                        snapshot: snapshot, issue: issue, status: issue ? "blocked" : "pending",
                        access_token: SecureRandom.urlsafe_base64(24), transfer_amount_vnd: nil,
                        qr_payload: nil, confirmed_at: nil, confirmed_by: nil, confirmed_by_telegram_id: nil,
                        summary_delivery: "idle", qr_delivery: "idle", summary_message_id: nil, qr_message_id: nil,
                        delivery_error: nil)
        AuditLogger.log!(actor: actor, action: refresh ? "payment_qr.refreshed" : "payment_qr.prepared",
                         auditable: request, before_data: before, after_data: request.audit_snapshot)
        if request.pending? && AppSetting.get("payment_qr_telegram_enabled")
          id = request.id
          ActiveRecord.after_all_transactions_commit { DeliverPaymentQrJob.perform_later(id, "summary") }
        end
      end
      request
    end
  end
end
