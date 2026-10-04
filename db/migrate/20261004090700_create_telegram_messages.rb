class CreateTelegramMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_messages do |t|
      t.references :telegram_chat, null: false, foreign_key: true
      t.bigint :telegram_message_id, null: false
      t.bigint :telegram_update_id
      t.bigint :telegram_sender_id
      t.string :sender_name
      t.string :media_group_id
      t.text :message_text
      t.datetime :sent_at
      t.string :processing_status, null: false, default: "received"
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
    end
    add_index :telegram_messages, [ :telegram_chat_id, :telegram_message_id ], unique: true, name: "index_telegram_messages_on_chat_and_message"
    add_index :telegram_messages, :telegram_update_id
    add_index :telegram_messages, :media_group_id
  end
end
