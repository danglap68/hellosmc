module Admin
  # OCR review queue. A review item is a transaction in needs_review / hold / failed.
  class ReviewsController < BaseController
    permission :reviews

    QUEUES = {
      "needs_review" => %w[needs_review],
      "hold" => %w[hold],
      "failed" => %w[failed]
    }.freeze

    before_action :set_transaction, only: %i[show update]

    def index
      @queue = QUEUES.key?(params[:queue]) ? params[:queue] : "needs_review"
      @counts = Transaction.where(status: QUEUES.values.flatten).group(:status).count
      scope = Transaction.where(status: QUEUES[@queue]).includes(:dealer, :merchant, :bill_image, :reviews).order(:created_at)
      @pagy, @transactions = pagy(scope)
    end

    def show
      @next_transaction = next_in_queue
    end

    # One form, several decisions: save_draft | approve | hold | reject | rerun_ocr
    def update
      case params[:decision]
      when "save_draft"
        return render_show_with_errors unless correct
        redirect_to admin_review_path(@transaction), notice: t("reviews.flash.saved")
      when "approve"
        return render_show_with_errors unless correct
        return render_show_with_errors unless Transactions::Approver.call(transaction: @transaction, actor: current_user, note: params[:note])
        redirect_to next_path, notice: t("transactions.flash.approved")
      when "hold", "reject"
        unless Transactions::StatusUpdater.call(transaction: @transaction, actor: current_user,
                                                action: params[:decision], note: params[:note])
          return render_show_with_errors
        end
        redirect_to next_path, notice: t("transactions.flash.#{params[:decision] == 'hold' ? 'held' : 'rejected'}")
      when "rerun_ocr"
        return render_show_with_errors unless Transactions::Reprocessor.call(transaction: @transaction, actor: current_user)
        redirect_to admin_reviews_path, notice: t("transactions.flash.reprocessing")
      else
        redirect_to admin_review_path(@transaction)
      end
    end

    private

    def set_transaction
      @transaction = Transaction.find(params[:id])
    end

    def correct
      return true unless @transaction.editable?

      Transactions::Corrector.call(transaction: @transaction, actor: current_user,
                                   params: correction_params, note: params[:note]).success?
    end

    def correction_params
      params.fetch(:transaction, {}).permit(*Transactions::Corrector::PERMITTED)
    end

    def render_show_with_errors
      @next_transaction = next_in_queue
      render :show, status: :unprocessable_content
    end

    def next_in_queue
      Transaction.review_queue.where.not(id: @transaction.id).order(:created_at).first
    end

    def next_path
      following = next_in_queue
      following ? admin_review_path(following) : admin_reviews_path
    end
  end
end
