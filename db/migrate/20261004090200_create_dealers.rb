class CreateDealers < ActiveRecord::Migration[8.1]
  def change
    create_table :dealers do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.boolean :active, null: false, default: true
      t.references :default_card_type, foreign_key: { to_table: :card_types }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :dealers, :code, unique: true
  end
end
