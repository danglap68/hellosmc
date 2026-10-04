module Admin
  class TransactionsController < BaseController
    permission :transactions

    before_action :set_transaction, except: :index

    def index
      @filter = Transactions::Filter.new(params)
      scope = @filter.apply(Transaction.includes(:dealer, :merchant, :card_type)).recent_first
      @pagy, @transactions = pagy(scope)
    end

    def show
      @audit_logs = @transaction.audit_logs.includes(:actor_user).recent_first
      @reviews = @transaction.reviews.includes(:reviewed_by).recent_first
    end

    def edit
      redirect_to(admin_transaction_path(@transaction), alert: t("transactions.flash.not_editable")) unless @transaction.editable?
    end

    def update
      result = Transactions::Corrector.call(transaction: @transaction, actor: current_user,
                                            params: correction_params, note: params[:note])
      if result.success?
        redirect_to admin_transaction_path(@transaction), notice: t("transactions.flash.corrected")
      else
        render :edit, status: :unprocessable_content
      end
    end

    def approve
      if Transactions::Approver.call(transaction: @transaction, actor: current_user, note: params[:note])
        redirect_back_or_to admin_transaction_path(@transaction), notice: t("transactions.flash.approved")
      else
        redirect_back_or_to admin_transaction_path(@transaction), alert: error_message
      end
    end

    def hold
      change_status("hold", t("transactions.flash.held"))
    end

    def reject
      change_status("reject", t("transactions.flash.rejected"))
    end

    def reprocess
      if Transactions::Reprocessor.call(transaction: @transaction, actor: current_user)
        redirect_to admin_transaction_path(@transaction), notice: t("transactions.flash.reprocessing")
      else
        redirect_to admin_transaction_path(@transaction), alert: error_message
      end
    end

    private

    def set_transaction
      @transaction = Transaction.find(params[:id])
    end

    def correction_params
      params.fetch(:transaction, {}).permit(*Transactions::Corrector::PERMITTED)
    end

    def change_status(action, notice)
      if Transactions::StatusUpdater.call(transaction: @transaction, actor: current_user, action: action, note: params[:note])
        redirect_back_or_to admin_transaction_path(@transaction), notice: notice
      else
        redirect_back_or_to admin_transaction_path(@transaction), alert: error_message
      end
    end

    def error_message
      @transaction.errors.full_messages.to_sentence.presence || t("flash.action_failed")
    end
  end
end
