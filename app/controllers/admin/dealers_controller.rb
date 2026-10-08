module Admin
  class DealersController < BaseController
    permission :dealers

    before_action :set_dealer, only: %i[show edit update destroy]

    def index
      scope = Dealer.includes(:default_card_type).ordered
      scope = scope.where("dealers.name ILIKE :q OR dealers.code ILIKE :q", q: "%#{Dealer.sanitize_sql_like(params[:q])}%") if params[:q].present?
      @pagy, @dealers = pagy(scope)
      @chat_counts = TelegramChat.where(dealer_id: @dealers.map(&:id)).group(:dealer_id).count
      @merchant_counts = Merchant.where(dealer_id: @dealers.map(&:id)).group(:dealer_id).count
    end

    def show
      @telegram_chats = @dealer.telegram_chats.ordered
      @merchants = @dealer.merchants.ordered
      @fee_rules = @dealer.fee_rules.includes(:card_types, :merchants).ordered
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
      params.require(:dealer).permit(:name, :code, :active, :default_card_type_id)
    end
  end
end
