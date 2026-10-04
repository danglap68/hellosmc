class CreateTelegramChats < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_chats do |t|
      t.bigint :telegram_chat_id, null: false
      t.string :name
      t.string :chat_type
      t.references :dealer, foreign_key: true
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :telegram_chats, :telegram_chat_id, unique: true
  end
end
