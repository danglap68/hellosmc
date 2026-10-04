class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.string :actor_type, null: false
      t.bigint :actor_id
      t.string :action, null: false
      t.string :auditable_type
      t.bigint :auditable_id
      t.jsonb :before_data
      t.jsonb :after_data
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :audit_logs, [ :auditable_type, :auditable_id ]
    add_index :audit_logs, [ :actor_type, :actor_id ]
    add_index :audit_logs, :action
    add_index :audit_logs, :created_at
  end
end
