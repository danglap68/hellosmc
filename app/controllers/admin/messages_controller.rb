module Admin
  class MessagesController < BaseController
    permission :messages

    THREAD_LIMIT = 80

    def index
      @health = Telegram::CollectionHealth.call
      @previews = Telegram::CollectionHealth.latest_messages
      @conversations = @health.rows.sort_by { |row| conversation_rank(row) }
      @chat = TelegramChat.find_by(id: params[:chat_id]) if params[:chat_id].present?
      @missing_ids = Telegram::CollectionHealth.missing_ids(@chat) if @chat && params[:gaps] == "1"
      @messages, @has_older = thread_for(@chat) if @chat
    end

    def show
      @message = TelegramMessage.find(params[:id])
    end

    private

    def conversation_rank(row)
      sent = @previews[row.chat.id]&.sent_at
      [ sent ? 0 : 1, -(sent&.to_f || 0), row.chat.display_name.to_s ]
    end

    # Latest window, drawn oldest-first so the thread reads like a chat.
    def thread_for(chat)
      scope = TelegramMessage.where(telegram_chat_id: chat.id)
      if (pivot = scope.find_by(id: params[:before_id]))&.sent_at
        scope = scope.where("(sent_at, id) < (?, ?)", pivot.sent_at, pivot.id)
      end
      ids = scope.order(Arel.sql("sent_at DESC NULLS LAST, id DESC")).limit(THREAD_LIMIT + 1).pluck(:id)
      has_older = ids.size > THREAD_LIMIT
      messages = TelegramMessage.for_list.where(id: ids.first(THREAD_LIMIT))
        .order(Arel.sql("sent_at ASC NULLS LAST, telegram_messages.id ASC"))
      [ messages, has_older ]
    end
  end
end
