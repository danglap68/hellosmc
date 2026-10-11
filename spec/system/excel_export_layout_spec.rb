require "rails_helper"

RSpec.describe "Excel export layout choice" do
  include_context "accounting setup"

  before { sign_in create(:user, :admin) }

  it "changes the column list with the selected export type and stores that type" do
    visit new_admin_excel_export_path

    expect(page).to have_select("Loại file", selected: "File hiện tại")
    expect(page).to have_css("[data-layout='legacy']", text: "Tên Đại lý")
    expect(page).to have_css("[data-layout='ket_toan_phi_goc']", visible: :hidden, text: "Tỷ lệ")
    expect(page).to have_content("bill hold")

    select "Kết toán theo phí gốc", from: "Loại file"
    fill_in "Từ ngày", with: "2026-10-05"
    fill_in "Đến ngày", with: "2026-10-05"
    perform_enqueued_jobs { click_button "Tạo file Excel" }

    export = ExcelExport.order(:id).last
    expect(export.layout).to eq("ket_toan_phi_goc")
    expect(export).to be_completed
    expect(export.filename).to match(/\Asmc-ket-toan-phi-goc-20261005-\d{6}\.xlsx\z/)

    visit admin_root_path
    expect(page).to have_no_content("Xuất kết toán phí gốc")
  end
end
