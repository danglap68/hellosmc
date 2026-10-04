require "rails_helper"

RSpec.describe "Transaction approval and export" do
  include_context "accounting setup"

  let(:admin) { create(:user, :admin) }
  let!(:transaction) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }

  before { sign_in admin }

  it "approves from the detail page, exports to Excel and leaves an audit trail" do
    visit admin_transaction_path(transaction)
    expect(page).to have_content("Lý do cần kiểm tra")
    click_button "Duyệt"
    expect(page).to have_content("Đã duyệt giao dịch.")
    expect(transaction.reload).to be_approved

    visit new_admin_excel_export_path
    fill_in "Từ ngày", with: "2026-10-04"
    fill_in "Đến ngày", with: "2026-10-04"
    perform_enqueued_jobs { click_button "Tạo file Excel" }

    export = ExcelExport.last
    expect(export).to be_completed
    expect(export.transaction_count).to eq(1)
    expect(transaction.reload).to be_exported

    visit admin_excel_export_path(export)
    click_link "Tải xuống"
    expect(page.response_headers["Content-Type"]).to include("spreadsheetml")

    visit admin_audit_logs_path
    expect(page).to have_content("Duyệt giao dịch")
    expect(page).to have_content("Tạo file Excel")
  end
end
