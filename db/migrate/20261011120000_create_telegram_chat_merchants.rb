class CreateTelegramChatMerchants < ActiveRecord::Migration[8.1]
  # A Telegram group ("TenDaiLy-HKD1-HKD2") can serve several HKDs, so the
  # single telegram_chats.merchant_id becomes a join table.
  def up
    create_table :telegram_chat_merchants do |t|
      t.references :telegram_chat, null: false, foreign_key: true
      t.references :merchant, null: false, foreign_key: true
      t.timestamps
    end
    add_index :telegram_chat_merchants, %i[telegram_chat_id merchant_id], unique: true,
              name: "index_telegram_chat_merchants_on_chat_and_merchant"

    execute <<~SQL.squish
      INSERT INTO telegram_chat_merchants (telegram_chat_id, merchant_id, created_at, updated_at)
      SELECT id, merchant_id, NOW(), NOW() FROM telegram_chats WHERE merchant_id IS NOT NULL
    SQL

    remove_reference :telegram_chats, :merchant, index: true
  end

  def down
    add_reference :telegram_chats, :merchant, index: true
    execute <<~SQL.squish
      UPDATE telegram_chats SET merchant_id = (
        SELECT merchant_id FROM telegram_chat_merchants
        WHERE telegram_chat_id = telegram_chats.id ORDER BY id LIMIT 1)
    SQL
    drop_table :telegram_chat_merchants
  end
end
