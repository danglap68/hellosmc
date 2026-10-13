require "rails_helper"

RSpec.describe "Toast messages" do
  before { Workbook::Seed.call }

  let(:admin) { create(:user, :admin) }
  let(:tk01) { MerchantDealer.find_by!(transfer_code: "TK01") }

  before { sign_in admin }

  def toasts
    Nokogiri::HTML(response.body).css(".app-toast-stack > .app-toast")
  end

  it "shows the flash notice of an action as a success toast that auto-dismisses" do
    patch admin_transfer_code_path(tk01), params: { merchant_dealer: { transfer_code: "tk 77" } }
    follow_redirect!

    toast = toasts.sole
    expect(toast["class"]).to include("app-toast-success")
    expect(toast["role"]).to eq("status")
    expect(toast["data-duration"].to_i).to be > 0
    expect(toast.at_css(".app-toast-title").text).to eq("Thành công")
    expect(toast.at_css(".app-toast-message").text).to eq("Đã lưu mã TK77.")
    expect(toast.at_css('button[data-action="toast#dismiss"][aria-label="Đóng thông báo"]')).to be_present
  end

  it "shows a flash alert as an error toast that stays until dismissed" do
    delete admin_user_path(admin)
    follow_redirect! while response.redirect?

    toast = toasts.sole
    expect(toast["class"]).to include("app-toast-error")
    expect(toast["role"]).to eq("alert")
    expect(toast["data-duration"]).to eq("0")
  end

  it "warns with an error toast when a form is sent back with errors" do
    patch admin_transfer_code_path(tk01), params: { merchant_dealer: { transfer_code: "tk02" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(toasts.sole.at_css(".app-toast-message").text).to include("Kiểm tra lại các trường")
  end

  it "renders no toast on a plain page, but keeps a template for client-side toasts" do
    get admin_settings_organization_transfer_codes_path

    expect(toasts).to be_empty
    expect(Nokogiri::HTML(response.body).at_css(".app-toast-stack template[data-toast-target='template']")).to be_present
  end
end
