require "rails_helper"

RSpec.describe "Dealers" do
  let(:merchant) { create(:merchant, name: "HKD AS CAFE-CAFE MILO", code: "MILO001") }
  let(:hue) { create(:dealer, name: "Chị Huệ", code: "CHIHUE") }

  before do
    sign_in create(:user, :admin)
    [ "tid127", "tid128", "tid129" ].each do |tid|
      create(:merchant_dealer, merchant: merchant, dealer: hue, tid_key: tid, tid_label: tid.upcase)
    end
  end

  it "lists an HKD once with all of the agent's TIDs" do
    get admin_dealer_path(hue)
    expect(response.body.scan("HKD AS CAFE-CAFE MILO").size).to eq(1)
    expect(response.body).to include("TID127", "TID128", "TID129")
  end

  it "counts distinct HKDs on the index" do
    get admin_dealers_path
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(controller.instance_variable_get(:@merchant_counts)[hue.id]).to eq(1)
  end

  it "shows recipient details, leading zeroes and a direct way to fill missing bank information" do
    complete = create(:dealer, name: "Đại lý đã có tài khoản", bank_bin: "970422", bank_account_number: "000123456",
                               bank_account_name: "NGUYEN VAN AN", auto_payment_qr: false)
    partial = create(:dealer, name: "Đại lý còn thiếu tên")
    partial.update_columns(bank_bin: "970422", bank_account_number: "001234", bank_account_name: nil)
    get admin_settings_organization_dealers_path

    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    complete_row = page.at_css(%([data-dealer-id="#{complete.id}"]))
    expect(complete_row.text).to include("MB", "000123456", "NGUYEN VAN AN")
    expect(complete_row.at_css("[data-bank-profile]")["data-bank-profile"]).to eq("complete")
    expect(complete_row.css(".dealer-bank-status")).to be_empty
    missing_row = page.at_css(%([data-dealer-id="#{hue.id}"]))
    expect(missing_row.text).to include("Chưa có tài khoản")
    expect(missing_row.at_css(".dealer-bank-status a")["href"]).to eq(edit_admin_dealer_path(hue, anchor: "dealer-bank-profile"))
    partial_row = page.at_css(%([data-dealer-id="#{partial.id}"]))
    expect(partial_row.text).to include("Chưa đầy đủ", "Thiếu: Chủ tài khoản", "001234")

    if ENV["SMC_DEALER_BANK_PREVIEW"] == "1"
      path = Rails.root.join("tmp/diagnostics/dealer-bank-preview#{ENV.fetch('TEST_ENV_NUMBER', '')}.html")
      FileUtils.mkdir_p(path.dirname)
      path.write(response.body)
    end
    get edit_admin_dealer_path(hue)
    expect(Nokogiri::HTML(response.body).at_css("section#dealer-bank-profile input[name='dealer[bank_account_number]']")).to be_present
  end

  it "filters missing and complete profiles without treating QR disabled as missing" do
    complete = create(:dealer, bank_bin: "970422", bank_account_number: "000123", bank_account_name: "NGUYEN VAN AN", auto_payment_qr: false)
    partial = create(:dealer)
    partial.update_columns(bank_bin: "970422", bank_account_number: "000123", bank_account_name: "   ")

    get admin_settings_organization_dealers_path(bank_profile: "missing")
    expect(controller.instance_variable_get(:@dealers)).to contain_exactly(hue, partial)
    get admin_settings_organization_dealers_path(bank_profile: "complete")
    expect(controller.instance_variable_get(:@dealers)).to contain_exactly(complete)
    get admin_settings_organization_dealers_path(bank_profile: "unexpected")
    expect(controller.instance_variable_get(:@dealers)).to contain_exactly(hue, partial, complete)
  end

  it "combines bank profile filters with search and activity and counts that same scope" do
    complete = create(:dealer, name: "Chị Mai", bank_bin: "970422", bank_account_number: "000123", bank_account_name: "NGUYEN VAN AN")
    create(:dealer, name: "Chị Mai cũ", active: false)
    get admin_settings_organization_dealers_path(bank_profile: "missing", q: "Chị", active: "1")
    expect(controller.instance_variable_get(:@dealers)).to contain_exactly(hue)
    expect(controller.instance_variable_get(:@bank_profile_counts)).to eq(complete: 1, missing: 1)
    expect(complete.reload.auto_payment_qr).to be(false)
  end

  it "keeps bank profile completion links hidden from viewers" do
    viewer = create(:user, :viewer)
    viewer.access_role.replace_grants!([ %w[dealers read] ])
    sign_in viewer
    get admin_settings_organization_dealers_path
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.at_css(%([data-dealer-id="#{hue.id}"])).text).to include("Chưa có tài khoản")
    expect(page.css(".dealer-bank-status a, tbody .row-actions")).to be_empty
  end
end
