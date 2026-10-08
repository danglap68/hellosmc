module Admin
  class FeeRulesController < BaseController
    permission :fee_rules

    before_action :set_fee_rule, only: %i[show edit update destroy]

    def index
      scope = FeeRule.includes(:merchants, :dealer, :card_types).ordered
      scope = scope.where(dealer_id: params[:dealer_id]) if params[:dealer_id].present?
      scope = scope.assigned_to_merchant(params[:merchant_id]) if params[:merchant_id].present?
      scope = scope.assigned_to_card_type(params[:card_type_id]) if params[:card_type_id].present?
      scope = scope.active.effective_at(Time.current) if params[:state] == "current"
      scope = scope.where(active: false) if params[:state] == "inactive"
      @pagy, @fee_rules = pagy(scope)
    end

    def show
      @audit_logs = AuditLog.where(auditable: @fee_rule).includes(:actor_user).recent_first
      @transaction_count = @fee_rule.transactions.count
    end

    def new
      @fee_rule = FeeRule.new(active: true, priority: 100, effective_from: Time.zone.today.beginning_of_day,
                              dealer_id: params[:dealer_id])
      @fee_rule.merchant_ids = [ params[:merchant_id] ] if params[:merchant_id].present?
    end

    def create
      @fee_rule = FeeRule.new(fee_rule_params)
      if @fee_rule.save
        audit!("fee_rule.created", @fee_rule)
        redirect_to admin_fee_rule_path(@fee_rule), notice: t("flash.created", model: FeeRule.model_name.human)
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      before = Audit::Snapshot.of(@fee_rule)
      if @fee_rule.update(fee_rule_params)
        audit!("fee_rule.updated", @fee_rule, before: before)
        redirect_to admin_fee_rule_path(@fee_rule), notice: t("flash.updated", model: FeeRule.model_name.human)
      else
        render :edit, status: :unprocessable_content
      end
    end

    # Rules already used by transactions cannot be deleted; deactivate them instead.
    def destroy
      before = Audit::Snapshot.of(@fee_rule)
      if @fee_rule.destroy
        audit!("fee_rule.destroyed", @fee_rule, before: before)
        redirect_to admin_fee_rules_path, notice: t("flash.destroyed", model: FeeRule.model_name.human), status: :see_other
      else
        redirect_to admin_fee_rule_path(@fee_rule), alert: t("fee_rules.flash.in_use"), status: :see_other
      end
    end

    private

    def set_fee_rule
      @fee_rule = FeeRule.find(params[:id])
    end

    def fee_rule_params
      params.require(:fee_rule).permit(:dealer_id, :base_fee_percent, :dealer_percent,
                                       :effective_from, :effective_until, :priority, :active, :note,
                                       merchant_ids: [], card_type_ids: [])
    end
  end
end
