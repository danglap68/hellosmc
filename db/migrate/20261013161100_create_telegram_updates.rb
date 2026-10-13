class CreateTelegramUpdates < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_updates do |t|
      t.bigint :update_id, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "received"
      t.integer :attempts, null: false, default: 0
      t.datetime :received_at, null: false
      t.datetime :processed_at
      t.timestamps
    end

    add_index :telegram_updates, :update_id, unique: true
    add_index :telegram_updates, [ :status, :updated_at ]
  end
end
