class CreateExcelExports < ActiveRecord::Migration[8.1]
  def change
    create_table :excel_exports do |t|
      t.date :export_date, null: false
      t.date :end_date, null: false
      t.string :status, null: false, default: "pending"
      t.integer :transaction_count, null: false, default: 0
      t.string :storage_key
      t.references :generated_by, foreign_key: { to_table: :users }
      t.datetime :generated_at
      t.text :error_message
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :excel_exports, :export_date
    add_check_constraint :excel_exports, "end_date >= export_date", name: "excel_exports_date_range"
    add_check_constraint :excel_exports, "status IN ('pending', 'processing', 'completed', 'failed')", name: "excel_exports_status_check"
  end
end
