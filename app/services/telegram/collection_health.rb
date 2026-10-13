module Telegram
  # Per-group counts for the messages page. A gap in message ids is only a hint:
  # deleted messages and other bots' messages leave gaps too.
  class CollectionHealth
    STATS_KEY = "telegram/collection_health/v1"
    PRIVACY_KEY = "telegram/can_read_all_group_messages/v1"
    WINDOW = 7.days
    SILENCE = 24.hours

    Row = Data.define(:chat, :last_sent_at, :today_count, :week_count, :missing_count, :silent)
    Snapshot = Data.define(:rows, :privacy_warning) do
      def silent_rows
        rows.select(&:silent)
      end
    end

    def self.call
      new.call
    end

    # One row per group: the newest message, without raw_payload.
    def self.latest_messages
      columns = (TelegramMessage.column_names - [ "raw_payload" ]).map { |name| %("#{name}") }.join(", ")
      TelegramMessage
        .select("DISTINCT ON (telegram_chat_id) #{columns}")
        .order(Arel.sql("telegram_chat_id, sent_at DESC NULLS LAST, id DESC"))
        .index_by(&:telegram_chat_id)
    end

    def self.missing_ids(chat, limit: 50)
      ids = chat.telegram_messages.where(sent_at: WINDOW.ago..).order(:telegram_message_id).pluck(:telegram_message_id)
      return [] if ids.size < 2

      missing = []
      ids.each_cons(2) do |left, right|
        next if right <= left + 1

        ((left + 1)...right).each do |id|
          missing << id
          return missing if missing.size >= limit
        end
      end
      missing
    end

    def call
      Snapshot.new(rows: rows, privacy_warning: privacy_warning?)
    end

    private

    def rows
      stats = self.class.stats_by_chat_id
      silence_before = SILENCE.ago
      TelegramChat.ordered.map do |chat|
        row = stats[chat.id] || {}
        last_sent_at = row["last_sent_at"]
        Row.new(
          chat: chat,
          last_sent_at: last_sent_at,
          today_count: row.fetch("today_count", 0),
          week_count: row.fetch("week_count", 0),
          missing_count: row.fetch("missing_count", 0),
          silent: chat.active? && (last_sent_at.nil? || last_sent_at < silence_before)
        )
      end
    end

    def privacy_warning?
      can_read_all_group_messages == false
    end

    def can_read_all_group_messages
      Rails.cache.fetch(PRIVACY_KEY, expires_in: 1.hour) do
        Timeout.timeout(2) { BotClient.new.get_me["can_read_all_group_messages"] }
      end
    rescue StandardError
      nil
    end

    class << self
      def stats_by_chat_id
        Rails.cache.fetch(STATS_KEY, expires_in: 1.minute) { uncached_stats }
      end

      def uncached_stats
        week = WINDOW.ago
        today = Time.zone.now.beginning_of_day
        sql = TelegramMessage.sanitize_sql_array([ <<~SQL, today, week, week, week ])
          SELECT telegram_chat_id,
                 MAX(sent_at) AS last_sent_at,
                 COUNT(*) FILTER (WHERE sent_at >= ?) AS today_count,
                 COUNT(*) FILTER (WHERE sent_at >= ?) AS week_count,
                 MIN(telegram_message_id) FILTER (WHERE sent_at >= ?) AS min_id,
                 MAX(telegram_message_id) FILTER (WHERE sent_at >= ?) AS max_id
          FROM telegram_messages
          GROUP BY telegram_chat_id
        SQL
        TelegramMessage.connection.select_all(sql).each_with_object({}) do |row, memo|
          week_count = row["week_count"].to_i
          min_id = row["min_id"]&.to_i
          max_id = row["max_id"]&.to_i
          missing = week_count >= 2 && min_id && max_id ? (max_id - min_id + 1 - week_count) : 0
          memo[row["telegram_chat_id"].to_i] = {
            "last_sent_at" => cast_time(row["last_sent_at"]),
            "today_count" => row["today_count"].to_i,
            "week_count" => week_count,
            "missing_count" => missing
          }
        end
      end

      def cast_time(value)
        case value
        when nil then nil
        when String then Time.zone.parse(value)
        else value.in_time_zone
        end
      end
    end
  end
end
