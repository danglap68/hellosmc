# Secrets admins manage in the UI (Telegram bot token, webhook secret).
# Values are encrypted with Active Record Encryption (keys derived from
# SECRET_KEY_BASE, see config/initializers/active_record_encryption.rb).
class CreateAppSecrets < ActiveRecord::Migration[8.1]
  def change
    create_table :app_secrets do |t|
      t.string :key, null: false
      t.text :value, null: false
      t.references :updated_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :app_secrets, :key, unique: true
  end
end
