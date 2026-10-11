class DropLegacyDealerColumns < ActiveRecord::Migration[8.1]
  # No backfill here: the old 1:1 merchant.dealer_id has no reliable TID, and a
  # synthetic "tid1" row would collide with the real (HKD, agent, TID) rows that
  # Workbook::Seed creates from the DS MB layout (unique index on merchant_id+tid_key).
  def up
    remove_reference :telegram_chats, :dealer, foreign_key: true
    remove_reference :merchants, :dealer, foreign_key: true
  end

  def down
    add_reference :merchants, :dealer, foreign_key: true
    add_reference :telegram_chats, :dealer, foreign_key: true
  end
end
