class AddMessageFieldsToTelegramMessages < ActiveRecord::Migration[8.1]
  SERVICE_KEYS = %w[
    new_chat_members left_chat_member new_chat_title new_chat_photo delete_chat_photo
    group_chat_created supergroup_chat_created channel_chat_created
    migrate_to_chat_id migrate_from_chat_id pinned_message
    message_auto_delete_timer_changed
  ].freeze

  def up
    add_column :telegram_messages, :kind, :string, null: false, default: "text"
    add_column :telegram_messages, :reply_to_message_id, :bigint
    add_column :telegram_messages, :forwarded_from, :string
    add_column :telegram_messages, :edited_at, :datetime
    backfill_kind
    add_index :telegram_messages, [ :telegram_chat_id, :sent_at ],
              order: { sent_at: :desc }, name: "index_telegram_messages_on_chat_id_and_sent_at"
    add_index :telegram_messages, :sent_at, order: { sent_at: :desc }
    add_trgm_index if enable_pg_trgm
  end

  def down
    if index_name_exists?(:telegram_messages, "index_telegram_messages_on_message_text_trgm")
      remove_index :telegram_messages, name: "index_telegram_messages_on_message_text_trgm"
    end
    remove_index :telegram_messages, name: "index_telegram_messages_on_sent_at"
    remove_index :telegram_messages, name: "index_telegram_messages_on_chat_id_and_sent_at"
    remove_column :telegram_messages, :edited_at
    remove_column :telegram_messages, :forwarded_from
    remove_column :telegram_messages, :reply_to_message_id
    remove_column :telegram_messages, :kind
  end

  private

  def backfill_kind
    keys = SERVICE_KEYS.map { |key| connection.quote(key) }.join(", ")
    execute <<~SQL.squish
      UPDATE telegram_messages
      SET kind = CASE
        WHEN msg ?| ARRAY[#{keys}] THEN 'service'
        WHEN jsonb_typeof(msg -> 'photo') = 'array' AND jsonb_array_length(msg -> 'photo') > 0 THEN 'photo'
        WHEN jsonb_typeof(msg -> 'document') = 'object' THEN 'document'
        WHEN jsonb_typeof(msg -> 'video') = 'object' OR jsonb_typeof(msg -> 'video_note') = 'object' THEN 'video'
        WHEN jsonb_typeof(msg -> 'voice') = 'object' THEN 'voice'
        WHEN jsonb_typeof(msg -> 'audio') = 'object' THEN 'audio'
        WHEN jsonb_typeof(msg -> 'sticker') = 'object' THEN 'sticker'
        WHEN jsonb_typeof(msg -> 'location') = 'object' OR jsonb_typeof(msg -> 'venue') = 'object' THEN 'location'
        WHEN jsonb_typeof(msg -> 'contact') = 'object' THEN 'contact'
        WHEN COALESCE(msg ->> 'text', msg ->> 'caption') IS NOT NULL
             AND COALESCE(msg ->> 'text', msg ->> 'caption') <> '' THEN 'text'
        ELSE 'other'
      END
      FROM (
        SELECT id,
               COALESCE(
                 raw_payload -> 'message',
                 raw_payload -> 'channel_post',
                 raw_payload -> 'edited_message',
                 raw_payload -> 'edited_channel_post',
                 '{}'::jsonb
               ) AS msg
        FROM telegram_messages
      ) src
      WHERE telegram_messages.id = src.id
    SQL
  end

  def enable_pg_trgm
    execute("SAVEPOINT pg_trgm_ext")
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    execute("RELEASE SAVEPOINT pg_trgm_ext")
    true
  rescue ActiveRecord::StatementInvalid
    execute("ROLLBACK TO SAVEPOINT pg_trgm_ext")
    false
  end

  def add_trgm_index
    add_index :telegram_messages, :message_text, using: :gin, opclass: :gin_trgm_ops,
              name: "index_telegram_messages_on_message_text_trgm"
  end
end
