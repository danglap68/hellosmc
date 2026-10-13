module Admin
  class MerchantsController < BaseController
    permission :merchants

    before_action :set_merchant, only: %i[show edit update destroy]

    def index
      scope = Merchant.includes(:default_card_type).ordered
      if params[:q].present?
        like = "%#{Merchant.sanitize_sql_like(params[:q])}%"
        normalized = "%#{VietnameseText.normalize(params[:q])}%"
        scope = scope.where("merchants.name ILIKE :like OR merchants.code ILIKE :like OR merchants.normalized_name LIKE :normalized",
                            like: like, normalized: normalized)
      end
      scope = apply_active_filter(scope)
      scope = scope.where(skip_bills: true) if params[:skip_bills] == "1"
      scope = apply_sort(scope, {
        "name_asc" => { name: :asc, id: :asc },
        "name_desc" => { name: :desc, id: :desc },
        "code" => { code: :asc, id: :asc },
        "newest" => { created_at: :desc, id: :desc }
      }, default: "name_asc")
      @pagy, @merchants = pagy(scope)
      @alias_counts = MerchantAlias.where(merchant_id: @merchants.map(&:id)).group(:merchant_id).count
    end

    def show
      @merchant_aliases = @merchant.merchant_aliases.order(:alias_type, :alias)
      @merchant_alias = @merchant.merchant_aliases.build(alias_type: "receipt_name")
      @fee_rules = @merchant.fee_rules.includes(:fee_rule_merchants, :fee_rule_card_types, :card_types, :dealer).ordered
    end

    def new
      @merchant = Merchant.new(active: true)
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

    def edit
      @merchant.merchant_dealers.build
    end

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
      params.require(:merchant).permit(:name, :code, :default_card_type_id, :active, :skip_bills,
        merchant_dealers_attributes: [ :id, :dealer_id, :tid_key, :tid_label, :ds_sheet_anchor, :ds_header, :rd_agent_label, :active, :_destroy ])
    end
  end
end
