module Admin
  class MessagesController < BaseController
    permission :messages

    THREAD_LIMIT = 80

    def index
      @health = Telegram::CollectionHealth.call
      @previews = Telegram::CollectionHealth.latest_messages
      @group_query = params[:group_q].to_s.strip.first(120)
      @query = params[:q].to_s.strip.first(200)
      @filter = params[:filter].in?(%w[active inactive]) ? params[:filter] : "all"
      @conversations = @health.rows.select { |row| conversation_matches?(row) }.sort_by { |row| conversation_rank(row) }
      @chat = params[:chat_id].present? ? TelegramChat.find(params[:chat_id]) : @conversations.first&.chat
      @chat_health = @health.rows.find { |row| row.chat.id == @chat&.id }
      @missing_ids = Telegram::CollectionHealth.missing_ids(@chat) if @chat && params[:gaps] == "1"
      if @chat
        @messages, @has_older = thread_for(@chat)
        reply_ids = @messages.filter_map(&:reply_to_message_id)
        @replies = @chat.telegram_messages.for_list.where(telegram_message_id: reply_ids).index_by(&:telegram_message_id)
      end
    end

    def show
      @message = TelegramMessage.find(params[:id])
    end

    private

    def conversation_matches?(row)
      return false if @filter == "active" && !row.chat.active?
      return false if @filter == "inactive" && row.chat.active?

      I18n.transliterate(row.chat.display_name).downcase.include?(I18n.transliterate(@group_query).downcase)
    end

    def conversation_rank(row)
      sent = @previews[row.chat.id]&.sent_at
      [ sent ? 0 : 1, -(sent&.to_f || 0), row.chat.display_name.to_s ]
    end

    # Latest window, drawn oldest-first so the thread reads like a chat.
    def thread_for(chat)
      scope = TelegramMessage.where(telegram_chat_id: chat.id)
      if @query.present?
        pattern = "%#{TelegramMessage.sanitize_sql_like(@query)}%"
        scope = scope.where("message_text ILIKE :query OR sender_name ILIKE :query", query: pattern)
        @search_count = scope.count
      end
      if (pivot = scope.find_by(id: params[:before_id]))
        scope = if pivot.sent_at
          scope.where("sent_at IS NULL OR (sent_at, id) < (?, ?)", pivot.sent_at, pivot.id)
        else
          scope.where(sent_at: nil).where("id < ?", pivot.id)
        end
        @older_window = true
      end
      ids = scope.order(Arel.sql("sent_at DESC NULLS LAST, id DESC")).limit(THREAD_LIMIT + 1).pluck(:id)
      has_older = ids.size > THREAD_LIMIT
      messages = TelegramMessage.for_list.where(id: ids.first(THREAD_LIMIT))
        .preload(:transactions, :remitter_transfer)
        .preload(bill_images: [ :image_attachment, { duplicate_of: :image_attachment } ])
        .order(Arel.sql("sent_at ASC NULLS LAST, telegram_messages.id ASC"))
      [ messages, has_older ]
    end
  end
end
