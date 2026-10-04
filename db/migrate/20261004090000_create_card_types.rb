class CreateCardTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :card_types do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      # Normalized tokens that identify this card type in Telegram message text (e.g. "mb", "napas").
      t.string :aliases, array: true, null: false, default: []
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :card_types, :key, unique: true
  end
end
