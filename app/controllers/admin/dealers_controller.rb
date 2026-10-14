module Admin
  class DealersController < BaseController
    permission :dealers

    before_action :set_dealer, only: %i[show edit update destroy]

    def index
      scope = Dealer.includes(:default_card_type)
      scope = scope.where("dealers.name ILIKE :q OR dealers.code ILIKE :q", q: "%#{Dealer.sanitize_sql_like(params[:q])}%") if params[:q].present?
      scope = apply_active_filter(scope)
      scope = apply_sort(scope, {
        "name_asc" => { name: :asc, id: :asc },
        "name_desc" => { name: :desc, id: :desc },
        "code" => { code: :asc, id: :asc },
        "newest" => { created_at: :desc, id: :desc }
      }, default: "name_asc")
      @pagy, @dealers = pagy(scope)
      @merchant_counts = MerchantDealer.where(dealer_id: @dealers.map(&:id)).group(:dealer_id).distinct.count(:merchant_id)
    end

    def show
      # One row per HKD even when the agent has several TIDs there.
      @merchants = @dealer.assigned_merchants.distinct.ordered
      @tids_by_merchant = @dealer.merchant_dealers.order(:tid_key).group_by(&:merchant_id)
      @fee_rules = @dealer.fee_rules.includes(:fee_rule_merchants, :merchants, :fee_rule_card_types, :card_types).ordered
    end

    def new
      @dealer = Dealer.new(active: true)
    end

    def create
      @dealer = Dealer.new(dealer_params)
      if @dealer.save
        audit!("dealer.created", @dealer)
        redirect_to admin_dealer_path(@dealer), notice: t("flash.created", model: Dealer.model_name.human)
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      before = Audit::Snapshot.of(@dealer)
      if @dealer.update(dealer_params)
        audit!("dealer.updated", @dealer, before: before)
        redirect_to admin_dealer_path(@dealer), notice: t("flash.updated", model: Dealer.model_name.human)
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      before = Audit::Snapshot.of(@dealer)
      if @dealer.destroy
        audit!("dealer.destroyed", @dealer, before: before)
        redirect_to admin_dealers_path, notice: t("flash.destroyed", model: Dealer.model_name.human), status: :see_other
      else
        redirect_to admin_dealer_path(@dealer), alert: @dealer.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private

    def set_dealer
      @dealer = Dealer.find(params[:id])
    end

    def dealer_params
      params.require(:dealer).permit(:name, :code, :active, :default_card_type_id,
                                    :bank_bin, :bank_account_number, :bank_account_name, :auto_payment_qr)
    end
  end
end
