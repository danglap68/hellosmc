module Admin
  # Transfers posted by remitters ("đi tiền"): review queue, approval and the
  # "thu chi" sheet write. They are never transactions.
  class RemitterTransfersController < BaseController
    permission :remitter_transfers

    QUEUES = {
      "all" => -> { RemitterTransfer.all },
      "needs_review" => -> { RemitterTransfer.needs_review },
      "not_written" => -> { RemitterTransfer.pending_write },
      "written" => -> { RemitterTransfer.where.not(written_at: nil) },
      "processing" => -> { RemitterTransfer.processing },
      "rejected" => -> { RemitterTransfer.where(status: %w[rejected failed]) }
    }.freeze

    before_action :set_transfer, only: %i[show update write retry_processing]

    def index
      @queue = QUEUES.key?(params[:queue]) ? params[:queue] : "all"
      @counts = QUEUES.transform_values { |scope| scope.call.accounting_records.count }
      scope = QUEUES.fetch(@queue).call.accounting_records.includes(:remitter, telegram_message: { bill_images: :duplicate_of },
                                                        bill_image: :duplicate_of, merchant_dealer: %i[dealer merchant])
      scope = scope.where(merchant_dealer_id: MerchantDealer.where(dealer_id: params[:dealer_id]).select(:id)) if params[:dealer_id].present?
      scope = apply_time_range(scope, :transferred_at)
      if params[:q].present?
        like = "%#{RemitterTransfer.sanitize_sql_like(params[:q])}%"
        matched = RemitterTransfer.left_joins(:remitter).where(
          "remitter_transfers.transfer_code ILIKE :q OR remitters.name ILIKE :q OR remitter_transfers.id::text = :id",
          q: like, id: params[:q].strip
        ).select(:id)
        scope = scope.where(id: matched)
      end
      scope = apply_sort(scope, {
        "newest" => { transferred_at: :desc, id: :desc },
        "oldest" => { transferred_at: :asc, id: :asc },
        "amount_desc" => { amount_vnd: :desc, id: :desc },
        "amount_asc" => { amount_vnd: :asc, id: :asc }
      }, default: "newest")
      @pagy, @transfers = pagy(scope)
    end

    def show
      @duplicate_check = RemitterTransfers::DuplicateDetector.call(transfer: @transfer, include_recorded: true)
    end

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

    def retry_processing
      result = RemitterTransfers::Retrier.call(transfer: @transfer, actor: current_user, lock_version: params[:lock_version])
      if result.ok?
        redirect_back_or_to admin_remitter_transfer_path(@transfer), notice: t("remitter_transfers.retry.queued.#{result.step}")
      else
        redirect_back_or_to admin_remitter_transfer_path(@transfer), alert: t("remitter_transfers.errors.#{result.error}")
      end
    end

    private

    def set_transfer
      @transfer = RemitterTransfer.includes(:remitter, :bill_image, telegram_message: :telegram_chat,
                                            merchant_dealer: %i[dealer merchant]).find(params[:id])
      if @transfer.non_transfer_image?
        redirect_to admin_message_path(@transfer.telegram_message), notice: t("remitter_transfers.flash.non_transfer_image")
      end
    end
  end
end
