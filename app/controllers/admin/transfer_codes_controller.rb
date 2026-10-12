module Admin
  # The transfer codes ("TK01") remitters write in the caption of a transfer
  # photo, listed in a card on Cài đặt. A code is a field of one agent row
  # (HKD + TID): these actions assign, change and clear that field; the rows
  # themselves are managed on the HKD page.
  class TransferCodesController < BaseController
    permission :transfer_codes

    before_action :set_link, only: %i[edit update destroy]

    def new
      @link = MerchantDealer.new
      @candidates = candidates
    end

    def create
      @link = MerchantDealer.find_by(id: params.dig(:merchant_dealer, :id), transfer_code: nil)
      return render_new_with(t("transfer_codes.errors.pick_agent")) unless @link

      before = Audit::Snapshot.of(@link)
      if @link.update(code_params)
        audit!("transfer_code.created", @link, before: before)
        redirect_to settings_codes_path, notice: t("transfer_codes.flash.created", code: @link.transfer_code)
      else
        @candidates = candidates
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      before = Audit::Snapshot.of(@link)
      if @link.update(code_params)
        audit!("transfer_code.updated", @link, before: before)
        redirect_to settings_codes_path, notice: t("transfer_codes.flash.updated", code: @link.transfer_code)
      else
        render :edit, status: :unprocessable_content
      end
    end

    # Clears the code of the row; the agent row itself stays.
    def destroy
      before = Audit::Snapshot.of(@link)
      code = @link.transfer_code
      if @link.update(transfer_code: nil)
        audit!("transfer_code.destroyed", @link, before: before)
        redirect_to settings_codes_path, notice: t("transfer_codes.flash.destroyed", code: code), status: :see_other
      else
        redirect_to settings_codes_path, alert: @link.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private

    def settings_codes_path
      admin_settings_path(codes: 1, anchor: "transfer-codes")
    end

    def set_link
      @link = MerchantDealer.where.not(transfer_code: nil).find(params[:id])
    end

    def code_params
      params.require(:merchant_dealer).permit(:transfer_code)
    end

    # Active agent rows that have no code yet.
    def candidates
      MerchantDealer.active.where(transfer_code: nil).includes(:merchant, :dealer).sort_by { |link| [ link.merchant.name, link.tid_key ] }
    end

    def render_new_with(message)
      @link = MerchantDealer.new
      @link.errors.add(:base, message)
      @candidates = candidates
      render :new, status: :unprocessable_content
    end
  end
end
