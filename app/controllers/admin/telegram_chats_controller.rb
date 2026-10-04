module Admin
  class TelegramChatsController < BaseController
    permission :telegram_chats

    before_action :set_chat, only: %i[show edit update destroy process_stored]

    def index
      scope = TelegramChat.includes(:dealer).ordered
      scope = scope.unmapped if params[:filter] == "unmapped"
      scope = scope.where(active: false) if params[:filter] == "inactive"
      @pagy, @telegram_chats = pagy(scope)
      @message_counts = TelegramMessage.where(telegram_chat_id: @telegram_chats.map(&:id)).group(:telegram_chat_id).count
    end

    def show
      @recent_messages = @telegram_chat.telegram_messages.order(sent_at: :desc).limit(20)
      @stored_image_count = @telegram_chat.telegram_messages.stored_unprocessed_images.count
    end

    # Processes images that arrived while the chat was inactive (once it is mapped and active).
    def process_stored
      unless @telegram_chat.active? && @telegram_chat.dealer
        return redirect_to(admin_telegram_chat_path(@telegram_chat), alert: t("telegram_chats.flash.activate_first"))
      end

      messages = @telegram_chat.telegram_messages.stored_unprocessed_images.to_a
      messages.each do |message|
        message.update!(processing_status: "queued")
        DownloadTelegramAttachmentJob.perform_later(message.id)
      end
      audit!("telegram_chat.stored_images_processed", @telegram_chat, metadata: { "telegram_message_ids" => messages.map(&:id) })
      redirect_to admin_telegram_chat_path(@telegram_chat), notice: t("telegram_chats.flash.processing_stored", count: messages.size)
    end

    def new
      @telegram_chat = TelegramChat.new(active: true)
    end

    def create
      @telegram_chat = TelegramChat.new(chat_params)
      if @telegram_chat.save
        audit!("telegram_chat.created", @telegram_chat)
        redirect_to admin_telegram_chats_path, notice: t("flash.created", model: TelegramChat.model_name.human)
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      before = Audit::Snapshot.of(@telegram_chat)
      if @telegram_chat.update(chat_params)
        audit!("telegram_chat.updated", @telegram_chat, before: before)
        redirect_to admin_telegram_chats_path, notice: t("flash.updated", model: TelegramChat.model_name.human)
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      before = Audit::Snapshot.of(@telegram_chat)
      if @telegram_chat.destroy
        audit!("telegram_chat.destroyed", @telegram_chat, before: before)
        redirect_to admin_telegram_chats_path, notice: t("flash.destroyed", model: TelegramChat.model_name.human), status: :see_other
      else
        redirect_to admin_telegram_chats_path, alert: @telegram_chat.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private

    def set_chat
      @telegram_chat = TelegramChat.find(params[:id])
    end

    def chat_params
      params.require(:telegram_chat).permit(:telegram_chat_id, :name, :dealer_id, :active)
    end
  end
end
