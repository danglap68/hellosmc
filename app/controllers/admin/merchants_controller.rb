module Admin
  class MerchantsController < BaseController
    permission :merchants

    before_action :set_merchant, only: %i[show edit update destroy]

    def index
      scope = Merchant.includes(:dealer, :default_card_type).ordered
      scope = scope.where(dealer_id: params[:dealer_id]) if params[:dealer_id].present?
      if params[:q].present?
        like = "%#{Merchant.sanitize_sql_like(params[:q])}%"
        normalized = "%#{VietnameseText.normalize(params[:q])}%"
        scope = scope.where("merchants.name ILIKE :like OR merchants.code ILIKE :like OR merchants.normalized_name LIKE :normalized",
                            like: like, normalized: normalized)
      end
      @pagy, @merchants = pagy(scope)
      @alias_counts = MerchantAlias.where(merchant_id: @merchants.map(&:id)).group(:merchant_id).count
    end

    def show
      @merchant_aliases = @merchant.merchant_aliases.order(:alias_type, :alias)
      @merchant_alias = @merchant.merchant_aliases.build(alias_type: "receipt_name")
      @fee_rules = @merchant.fee_rules.includes(:card_types, :dealer).ordered
    end

    def new
      @merchant = Merchant.new(active: true, dealer_id: params[:dealer_id])
    end

    def create
      @merchant = Merchant.new(merchant_params)
      if @merchant.save
        audit!("merchant.created", @merchant)
        redirect_to admin_merchant_path(@merchant), notice: t("flash.created", model: Merchant.model_name.human)
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      before = Audit::Snapshot.of(@merchant)
      if @merchant.update(merchant_params)
        audit!("merchant.updated", @merchant, before: before)
        redirect_to admin_merchant_path(@merchant), notice: t("flash.updated", model: Merchant.model_name.human)
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      before = Audit::Snapshot.of(@merchant)
      if @merchant.destroy
        audit!("merchant.destroyed", @merchant, before: before)
        redirect_to admin_merchants_path, notice: t("flash.destroyed", model: Merchant.model_name.human), status: :see_other
      else
        redirect_to admin_merchant_path(@merchant), alert: @merchant.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private

    def set_merchant
      @merchant = Merchant.find(params[:id])
    end

    def merchant_params
      params.require(:merchant).permit(:name, :code, :dealer_id, :default_card_type_id, :active)
    end
  end
end
