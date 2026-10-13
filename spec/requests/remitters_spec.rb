require "rails_helper"

RSpec.describe "Remitters admin" do
  before { sign_in create(:user, :admin) }

  it "creates a remitter with normalized fields" do
    post admin_remitters_path, params: { remitter: { name: "Lập", excel_key: "LẬP",
                                                     telegram_user_id: "123", telegram_username: "@lap" } }
    expect(response).to redirect_to(admin_remitters_path)
    remitter = Remitter.last
    expect(remitter.name).to eq("Lập")
    expect(remitter.excel_key).to eq("LẬP")
    expect(remitter.telegram_user_id).to eq(123)
    expect(remitter.telegram_username).to eq("lap")
  end

  it "lists remitters" do
    create(:remitter, name: "Lập", excel_key: "LẬP")
    get admin_remitters_path
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Lập")
  end

  it "updates a remitter" do
    remitter = create(:remitter, name: "Lập", excel_key: "LẬP")
    patch admin_remitter_path(remitter), params: { remitter: { name: "Lập", excel_key: "LẬP", telegram_user_id: "999" } }
    expect(response).to redirect_to(admin_remitters_path)
    expect(remitter.reload.telegram_user_id).to eq(999)
  end

  it "rejects a duplicate excel_key" do
    create(:remitter, name: "Lập", excel_key: "LẬP")
    post admin_remitters_path, params: { remitter: { name: "Khác", excel_key: "lập" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(Remitter.count).to eq(1)
  end
end
