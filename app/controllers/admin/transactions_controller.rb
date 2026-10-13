module Admin
  class TransactionsController < BaseController
    permission :transactions

    SORTS = {
      "newest" => { created_at: :desc, id: :desc },
      "oldest" => { created_at: :asc, id: :asc },
      "when_desc" => { transaction_at: :desc, id: :desc },
      "when_asc" => { transaction_at: :asc, id: :asc },
      "amount_desc" => { transaction_amount_vnd: :desc, id: :desc },
      "amount_asc" => { transaction_amount_vnd: :asc, id: :asc }
    }.freeze

    before_action :set_transaction, except: :index

    def index
      @filter = Transactions::Filter.new(params)
      scope = apply_sort(@filter.apply(Transaction.includes(:dealer, :merchant, :card_type)), SORTS, default: "newest")
      @pagy, @transactions = pagy(scope)
    end

    def show
      @audit_logs = @transaction.audit_logs.includes(:actor_user).recent_first
      @reviews = @transaction.reviews.includes(:reviewed_by).recent_first
      @status_versions = @transaction.versions.where("object_changes -> 'status' IS NOT NULL")
        .reorder(created_at: :desc, id: :desc).to_a
      @version_users = User.where(id: @status_versions.filter_map(&:whodunnit)).index_by { |user| user.id.to_s }
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

    def include_excluded
      if Transactions::Includer.call(transaction: @transaction, actor: current_user)
        redirect_to admin_transaction_path(@transaction), notice: t("transactions.flash.included")
      else
        redirect_to admin_transaction_path(@transaction), alert: error_message
      end
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
