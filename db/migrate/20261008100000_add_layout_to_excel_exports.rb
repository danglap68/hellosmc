class AddLayoutToExcelExports < ActiveRecord::Migration[8.1]
  def change
    add_column :excel_exports, :layout, :string, null: false, default: "legacy"
    add_check_constraint :excel_exports,
      "layout IN ('legacy', 'ket_toan_phi_goc')",
      name: "excel_exports_layout_check"
  end
end
