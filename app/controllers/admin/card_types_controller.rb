module Admin
  class CardTypesController < BaseController
    permission :card_types

    before_action :set_card_type, only: %i[edit update destroy]

    def index
      @card_types = CardType.ordered
    end

    def new
      @card_type = CardType.new(active: true)
    end

    def create
      @card_type = CardType.new(card_type_params)
      if @card_type.save
        audit!("card_type.created", @card_type)
        redirect_to admin_card_types_path, notice: t("flash.created", model: CardType.model_name.human)
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      before = Audit::Snapshot.of(@card_type)
      if @card_type.update(card_type_params)
        audit!("card_type.updated", @card_type, before: before)
        redirect_to admin_card_types_path, notice: t("flash.updated", model: CardType.model_name.human)
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      before = Audit::Snapshot.of(@card_type)
      if @card_type.destroy
        audit!("card_type.destroyed", @card_type, before: before)
        redirect_to admin_card_types_path, notice: t("flash.destroyed", model: CardType.model_name.human), status: :see_other
      else
        redirect_to admin_card_types_path, alert: @card_type.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private

    def set_card_type
      @card_type = CardType.find(params[:id])
    end

    def card_type_params
      permitted = params.require(:card_type).permit(:key, :name, :aliases_text, :position, :active)
      permitted.delete(:key) if @card_type&.persisted?
      permitted
    end
  end
end
