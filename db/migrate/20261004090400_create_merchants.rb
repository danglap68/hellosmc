class CreateMerchants < ActiveRecord::Migration[8.1]
  def change
    create_table :merchants do |t|
      t.references :dealer, foreign_key: true
      t.string :name, null: false
      t.string :normalized_name, null: false
      t.string :code, null: false
      t.boolean :active, null: false, default: true
      t.references :default_card_type, foreign_key: { to_table: :card_types }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :merchants, :code, unique: true
    add_index :merchants, :normalized_name
  end
end
