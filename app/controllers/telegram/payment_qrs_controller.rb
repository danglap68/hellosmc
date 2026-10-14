module Telegram
  class PaymentQrsController < ActionController::Base
    # JSON actions authenticate only with fresh, signed Telegram initData, not
    # the admin session. The public GET shell contains no account information.
    protect_from_forgery with: :exception
    skip_forgery_protection only: %i[context decide]
    before_action :no_cache
    before_action :authenticate_telegram!, only: %i[context decide]

    def show
      render layout: false
    end

    def context
      render json: presentation
    end

    def decide
      PaymentQrs::Decide.call(request: @payment_qr, decision: params[:decision], amount: params[:amount],
                             version: params[:version], telegram_user_id: @telegram_identity.fetch(:user_id))
      render json: presentation
    rescue ::PaymentQrs::Error => e
      render json: { error: e.message }, status: :conflict
    end

    private

    def no_cache
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
      # Telegram Web embeds Mini Apps in an iframe. Scope this exception to
      # the Mini App; the admin keeps Rails' SAMEORIGIN protection.
      response.headers.delete("X-Frame-Options")
      response.headers["Content-Security-Policy"] = "frame-ancestors 'self' https://web.telegram.org"
    end

    def authenticate_telegram!
      @telegram_identity = MiniAppAuth.call(params[:init_data])
      start = @telegram_identity.fetch(:start_param)
      raise MiniAppAuth::Invalid, "Liên kết yêu cầu không hợp lệ." unless start.match?(/\Apqr_[a-zA-Z0-9_-]{32}\z/)

      @payment_qr = DealerPaymentQr.find_by!(access_token: start.delete_prefix("pqr_"))
      ::PaymentQrs::TelegramAccess.authorize!(@payment_qr, user_id: @telegram_identity.fetch(:user_id))
    rescue MiniAppAuth::Invalid, ::PaymentQrs::Error, ActiveRecord::RecordNotFound => e
      render json: { error: e.is_a?(ActiveRecord::RecordNotFound) ? "Yêu cầu không còn tồn tại." : e.message }, status: :forbidden
    end

    def presentation
      data = @payment_qr.snapshot.slice("dealer_name", "merchant_name", "bank_name", "account_number", "account_name", "transfer_code", "dealer_amount_vnd")
      data.merge(id: @payment_qr.transaction_id, status: @payment_qr.status, version: @payment_qr.lock_version,
                 transfer_amount_vnd: @payment_qr.transfer_amount_vnd,
                 qr_payload: @payment_qr.confirmed? ? @payment_qr.qr_payload : nil,
                 qr_png: @payment_qr.confirmed? ? Base64.strict_encode64(::PaymentQrs::Vietqr.png(@payment_qr.qr_payload)) : nil)
    end
  end
end
