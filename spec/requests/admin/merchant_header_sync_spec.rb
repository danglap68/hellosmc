require "rails_helper"

RSpec.describe "Merchant DS MB header sync" do
  let(:hkd) { create(:merchant, name: "Cherry Coffee", code: "CHERRY001") }
  let!(:link) do
    create(:merchant_dealer, merchant: hkd, dealer: create(:dealer, name: "Nghĩa Nghiệp"), tid_key: "tid1",
           ds_sheet_anchor: "Cherry Coffee", ds_header: "Nghĩa Nghiệp (tid1)")
  end
  let(:month) { Time.current.month }
  let(:sheet) { Workbook::MemorySheet.new("DS MB T#{month}" => [ [ "Cherry Coffee", "Nghĩa (tid1)" ] ]) }

  before do
    AppSetting.create!(key: "hello_smc_spreadsheet_id", value: "1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-aBc")
    allow(Workbook::GoogleSheetClient).to receive(:new).and_return(sheet)
  end

  it "checks the HKD's headers and says what changed" do
    sign_in create(:user, :admin)

    get admin_merchant_path(hkd)
    expect(response.body).to include("Đồng bộ header")

    post sync_headers_admin_merchant_path(hkd)

    expect(response).to redirect_to(admin_merchant_path(hkd))
    expect(flash[:notice]).to eq("Đã kiểm tra DS MB T#{month}: khớp 0, đổi tên 1, đổi đại lý 0, chưa xác định 0, không thấy cột 0.")
    expect(link.reload.ds_header).to eq("Nghĩa (tid1)")
  end

  it "shows the reason when the sheet cannot be read" do
    sign_in create(:user, :admin)
    allow(Workbook::GoogleSheetClient).to receive(:new).and_raise(StandardError, "không mở được")

    post sync_headers_admin_merchant_path(hkd)

    expect(flash[:alert]).to eq("Không đồng bộ được header: không mở được")
  end

  it "is not offered to a viewer" do
    sign_in create(:user, :viewer)

    get admin_merchant_path(hkd)
    expect(response.body).not_to include("Đồng bộ header")

    post sync_headers_admin_merchant_path(hkd)
    expect(response).to have_http_status(:forbidden)
    expect(link.reload.ds_header).to eq("Nghĩa Nghiệp (tid1)")
  end
end
