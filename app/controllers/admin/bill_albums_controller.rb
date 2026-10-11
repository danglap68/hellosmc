module Admin
  # Read-only view of Telegram bill albums and their reconciliation result.
  class BillAlbumsController < BaseController
    permission :bill_albums

    def index
      @pagy, @bill_albums = pagy(BillAlbum.includes(:telegram_chat).recent_first)
    end

    def show
      @bill_album = BillAlbum.includes(:telegram_chat, :transfer_bill_image, bill_images: :transactions).find(params[:id])
    end
  end
end
