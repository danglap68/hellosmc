# Lookups by Telegram sender (remitter form suggestions, username fill-in)
# and by recent date. Built concurrently: telegram_messages grows with every
# group message and must stay writable during the deploy.
class AddSenderAndCreatedAtIndexesToTelegramMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :telegram_messages, :telegram_sender_id, algorithm: :concurrently, if_not_exists: true
    add_index :telegram_messages, :created_at, algorithm: :concurrently, if_not_exists: true
  end
end
