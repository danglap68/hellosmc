module Admin
  class MerchantAliasesController < BaseController
    permission :merchants

    before_action :set_merchant
    before_action :set_alias, only: %i[edit update destroy]

    def create
      @merchant_alias = @merchant.merchant_aliases.build(alias_params)
      if @merchant_alias.save
        audit!("alias.created", @merchant_alias, metadata: { "merchant_id" => @merchant.id })
        redirect_to admin_merchant_path(@merchant), notice: t("flash.created", model: MerchantAlias.model_name.human)
      else
        @merchant_aliases = @merchant.merchant_aliases.where.not(id: nil).order(:alias_type, :alias)
        @fee_rules = @merchant.fee_rules.includes(:card_type, :dealer).ordered
        render "admin/merchants/show", status: :unprocessable_content
      end
    end

    def edit; end

    def update
      before = Audit::Snapshot.of(@merchant_alias)
      if @merchant_alias.update(alias_params)
        audit!("alias.updated", @merchant_alias, before: before, metadata: { "merchant_id" => @merchant.id })
        redirect_to admin_merchant_path(@merchant), notice: t("flash.updated", model: MerchantAlias.model_name.human)
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      before = Audit::Snapshot.of(@merchant_alias)
      @merchant_alias.destroy!
      audit!("alias.destroyed", @merchant_alias, before: before, metadata: { "merchant_id" => @merchant.id })
      redirect_to admin_merchant_path(@merchant), notice: t("flash.destroyed", model: MerchantAlias.model_name.human), status: :see_other
    end

    private

    def set_merchant
      @merchant = Merchant.find(params[:merchant_id])
    end

    def set_alias
      @merchant_alias = @merchant.merchant_aliases.find(params[:id])
    end

    def alias_params
      params.require(:merchant_alias).permit(:alias, :alias_type, :active)
    end
  end
end
