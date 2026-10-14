module Admin
  class DealerPaymentQrsController < BaseController
    permission :transactions

    def create
      transaction = Transaction.find(params[:transaction_id])
      qr = PaymentQrs::Prepare.call(transaction, actor: current_user, refresh: params[:refresh] == "1")
      redirect_to admin_dealer_payment_qr_path(qr)
    rescue PaymentQrs::Error => e
      redirect_to admin_transaction_path(transaction), alert: e.message
    end

    def show
      response.headers["Cache-Control"] = "no-store"
      @payment_qr = DealerPaymentQr.find(params[:id])
      @current = @payment_qr.current?
      return unless request.format.png?

      if @current && @payment_qr.confirmed?
        response.headers["Cache-Control"] = "no-store"
        send_data PaymentQrs::Vietqr.png(@payment_qr.qr_payload), type: "image/png", disposition: "inline",
                  filename: "SMC-#{@payment_qr.transaction_id}-#{@payment_qr.snapshot['transfer_code']}.png"
      else
        head :conflict
      end
    end

    def update
      qr = DealerPaymentQr.find(params[:id])
      PaymentQrs::Decide.call(request: qr, decision: params[:decision], amount: params[:amount],
                             version: params[:version], actor: current_user)
      redirect_to admin_dealer_payment_qr_path(qr), notice: "Đã lưu quyết định tiền đi."
    rescue PaymentQrs::Error => e
      redirect_to admin_dealer_payment_qr_path(qr), alert: e.message
    end
  end
end
