module Admin
  # Transfers posted by remitters ("đi tiền"): review queue, approval and the
  # "thu chi" sheet write. They are never transactions.
  class RemitterTransfersController < BaseController
    permission :remitter_transfers

    QUEUES = {
      "needs_review" => -> { RemitterTransfer.needs_review },
      "not_written" => -> { RemitterTransfer.pending_write },
      "written" => -> { RemitterTransfer.where.not(written_at: nil) },
      "processing" => -> { RemitterTransfer.processing },
      "rejected" => -> { RemitterTransfer.where(status: %w[rejected failed]) }
    }.freeze

    before_action :set_transfer, only: %i[show update write]

    def index
      @queue = QUEUES.key?(params[:queue]) ? params[:queue] : "needs_review"
      @counts = QUEUES.transform_values { |scope| scope.call.count }
      scope = QUEUES.fetch(@queue).call.includes(:remitter, :telegram_message, bill_image: :duplicate_of, merchant_dealer: %i[dealer merchant])
      @pagy, @transfers = pagy(scope.recent_first)
    end

    def show; end

    def update
      result =
        if params[:decision] == "reject"
          RemitterTransfers::Reviewer.reject(transfer: @transfer, actor: current_user, lock_version: params[:lock_version])
        else
          RemitterTransfers::Reviewer.approve(
            transfer: @transfer, actor: current_user, lock_version: params[:lock_version],
            code: params.dig(:remitter_transfer, :transfer_code), amount: params.dig(:remitter_transfer, :amount_vnd),
            remitter_id: params.dig(:remitter_transfer, :remitter_id)
          )
        end

      if result.ok?
        notice = params[:decision] == "reject" ? t("remitter_transfers.flash.rejected") : t("remitter_transfers.flash.approved")
        redirect_to admin_remitter_transfer_path(@transfer), notice: notice
      else
        redirect_to admin_remitter_transfer_path(@transfer),
                    alert: result.errors.map { |error| t("remitter_transfers.errors.#{error}") }.to_sentence
      end
    end

    # Queues the sheet write again (e.g. the day's tab was created afterwards).
    def write
      if @transfer.writable? && !@transfer.written?
        WriteRemitterReportJob.perform_later(@transfer.id)
        redirect_to admin_remitter_transfer_path(@transfer), notice: t("remitter_transfers.flash.write_queued")
      else
        redirect_to admin_remitter_transfer_path(@transfer), alert: t("remitter_transfers.errors.not_writable")
      end
    end

    private

    def set_transfer
      @transfer = RemitterTransfer.includes(:remitter, :bill_image, telegram_message: :telegram_chat,
                                            merchant_dealer: %i[dealer merchant]).find(params[:id])
    end
  end
end
