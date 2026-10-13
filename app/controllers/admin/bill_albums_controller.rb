module Admin
  # Read-only view of Telegram bill albums and their reconciliation result.
  class BillAlbumsController < BaseController
    permission :bill_albums

    def index
      scope = BillAlbum.includes(:telegram_chat)
      scope = scope.where(status: params[:status]) if params[:status].in?(BillAlbum::STATUSES)
      scope = scope.where(reconciliation_status: params[:reconciliation_status]) if params[:reconciliation_status].in?(BillAlbum::RECONCILIATION_STATUSES)
      scope = scope.where(telegram_chat_id: params[:telegram_chat_id]) if params[:telegram_chat_id].present?
      scope = apply_time_range(scope, :created_at)
      if params[:q].present?
        like = "%#{BillAlbum.sanitize_sql_like(params[:q])}%"
        matched = BillAlbum.left_joins(:telegram_chat).where(
          "telegram_chats.name ILIKE :q OR bill_albums.media_group_id ILIKE :q OR bill_albums.id::text = :id",
          q: like, id: params[:q].strip
        ).select(:id)
        scope = scope.where(id: matched)
      end
      scope = apply_sort(scope, {
        "newest" => { created_at: :desc, id: :desc },
        "oldest" => { created_at: :asc, id: :asc },
        "amount_desc" => { child_total_vnd: :desc, id: :desc },
        "amount_asc" => { child_total_vnd: :asc, id: :asc }
      }, default: "newest")
      @pagy, @bill_albums = pagy(scope)
    end

    def show
      @bill_album = BillAlbum.includes(:telegram_chat, :transfer_bill_image, bill_images: :transactions).find(params[:id])
    end
  end
end
