require "rails_helper"

RSpec.describe "Transfer codes" do
  before { Workbook::Seed.call }

  let(:admin) { create(:user, :admin) }
  let(:tk01) { MerchantDealer.find_by!(transfer_code: "TK01") }

  context "as an admin" do
    before { sign_in admin }

    it "lists every code with its HKD, agent and TID under Cài đặt › Tổ chức" do
      get admin_settings_organization_transfer_codes_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Mã chuyển tiền", "TK01", "NM03", "Chương", "tid1", "Thêm mã")
      expect(response.body).to include(edit_admin_transfer_code_path(tk01))
      expect(Nokogiri::HTML(response.body).at_css('.settings-tab[aria-current="page"]').text.strip).to eq("Tổ chức")
    end

    it "puts a copy button next to each code" do
      get admin_settings_organization_transfer_codes_path

      button = Nokogiri::HTML(response.body).at_css('button[data-controller="clipboard"][data-clipboard-text-value="TK01"]')
      expect(button).to be_present
      expect(button["type"]).to eq("button")
      expect(button["aria-label"]).to eq("Chép mã TK01")
      expect(button["data-clipboard-copied-value"]).to eq("Đã chép")
      expect(button.at_css("i.ti-copy")).to be_present
    end

    it "moves the old address and the card off the Ứng dụng page" do
      get admin_transfer_codes_path
      expect(response).to redirect_to(admin_settings_organization_transfer_codes_path)

      get admin_settings_organization_transfer_codes_path
      expect(response.body).not_to include('id="transfer-codes"', 'href="/admin/settings#ma-chuyen"')
    end

    it "finds a code by HKD or agent name" do
      get admin_settings_organization_transfer_codes_path(q: "Chương")

      expect(response.body).to include("TK01")
      expect(response.body).not_to include(">NM03<")
    end

    it "changes a code, and the matcher follows at once" do
      patch admin_transfer_code_path(tk01), params: { merchant_dealer: { transfer_code: "tk 77" } }

      expect(response).to redirect_to(admin_settings_organization_transfer_codes_path)
      expect(flash[:notice]).to eq("Đã lưu mã TK77.")
      expect(tk01.reload.transfer_code).to eq("TK77")
      expect(RemitterTransfers::CodeMatcher.call("Lap chuyen tien TK77").code).to eq("TK77")
      expect(AuditLog.where(action: "transfer_code.updated", auditable: tk01)).to exist
    end

    it "refuses a code that is already used or badly formed" do
      patch admin_transfer_code_path(tk01), params: { merchant_dealer: { transfer_code: "tk02" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(tk01.reload.transfer_code).to eq("TK01")

      patch admin_transfer_code_path(tk01), params: { merchant_dealer: { transfer_code: "TK-1" } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "gives a code to an agent row that has none" do
      row = Merchant.find_by!(code: "001").merchant_dealers.find_by!(tid_key: "tid1")
      row.update!(transfer_code: nil)

      get new_admin_transfer_code_path
      expect(response.body).to include("Chương")

      post admin_transfer_codes_path, params: { merchant_dealer: { id: row.id, transfer_code: "tk09" } }

      expect(response).to redirect_to(admin_settings_organization_transfer_codes_path)
      expect(row.reload.transfer_code).to eq("TK09")
    end

    it "does not let a row that already has a code be picked again, or nothing be picked" do
      post admin_transfer_codes_path, params: { merchant_dealer: { id: tk01.id, transfer_code: "ZZ01" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(tk01.reload.transfer_code).to eq("TK01")

      post admin_transfer_codes_path, params: { merchant_dealer: { transfer_code: "ZZ01" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(MerchantDealer.where(transfer_code: "ZZ01")).to be_empty
    end

    it "clears the code on Xoá and keeps the agent row" do
      delete admin_transfer_code_path(tk01)

      expect(response).to redirect_to(admin_settings_organization_transfer_codes_path)
      expect(tk01.reload.transfer_code).to be_nil
      expect(tk01).to be_active
      expect(RemitterTransfers::Codes.codes).not_to include("TK01")
      expect(AuditLog.where(action: "transfer_code.destroyed", auditable: tk01)).to exist
    end

    it "tells how many active agents still have no code" do
      Merchant.find_by!(code: "001").merchant_dealers.find_by!(tid_key: "tid1").update!(transfer_code: nil)

      get admin_settings_organization_transfer_codes_path

      expect(response.body).to include("1 đại lý đang hoạt động chưa có mã")
    end
  end

  it "keeps an operator and a viewer out of the codes' actions" do
    [ :operator, :viewer ].each do |role|
      sign_in create(:user, role)

      get new_admin_transfer_code_path
      expect(response).to have_http_status(:forbidden)

      patch admin_transfer_code_path(tk01), params: { merchant_dealer: { transfer_code: "ZZ01" } }
      expect(response).to have_http_status(:forbidden)
      expect(tk01.reload.transfer_code).to eq("TK01")
    end
  end
end
