# Groups no longer list the HKDs they serve: the HKD and the agent are read
# from the bill (docs/SPEC_SIMPLIFY_SETTINGS.md §3.5).
class DropTelegramChatMerchants < ActiveRecord::Migration[8.1]
  def change
    drop_table :telegram_chat_merchants do |t|
      t.references :telegram_chat, null: false, foreign_key: true
      t.references :merchant, null: false, foreign_key: true
      t.timestamps
      t.index [ :telegram_chat_id, :merchant_id ], unique: true, name: "index_telegram_chat_merchants_on_chat_and_merchant"
    end
  end
end
