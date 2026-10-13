require "rails_helper"

# Every configuration table ends with the same Sửa / Xoá actions.
RSpec.describe "Row actions of the configuration tables" do
  include_context "accounting setup"

  let(:admin) { create(:user, :admin) }
  let(:operator) { create(:user, :operator) }

  let(:pages) do
    {
      "merchants" => admin_merchants_path,
      "dealers" => admin_dealers_path,
      "card types" => admin_card_types_path,
      "fee rules" => admin_fee_rules_path,
      "remitters" => admin_remitters_path,
      "Telegram groups" => admin_telegram_chats_path,
      "users" => admin_users_path,
      "transfer codes" => admin_transfer_codes_path
    }
  end

  before do
    create(:user, :operator, name: "Người khác")
    create(:remitter, name: "Người thử")
    create(:merchant_dealer, transfer_code: "TK01")
    create(:telegram_chat, name: "Nhóm thử")
    default_rule
  end

  it "gives every row a three-dot menu with Sửa and Xoá to someone who can manage the table" do
    sign_in admin

    pages.each do |name, path|
      get path
      follow_redirect! if response.redirect?
      body = Nokogiri::HTML(response.body)
      row = body.css("tbody tr").find { |tr| tr.css("button").any? { |button| button.text.strip == "Xoá" } }

      expect(row).to be_present, "#{name}: no row with a Xoá button"
      expect(row.at_css(%(.row-actions button[data-bs-toggle="dropdown"][aria-label="Thao tác khác"]))).to be_present, "#{name}: no three-dot toggle"
      expect(row.css(".row-actions .dropdown-menu a.dropdown-item").map { _1.text.strip }).to include("Sửa")
      delete = row.css(".row-actions .dropdown-menu button.dropdown-item.text-danger").find { |button| button.text.strip == "Xoá" }
      expect(delete).to be_present, "#{name}: no Xoá button"
      expect(row.at_css("form[data-turbo-confirm]")).to be_present, "#{name}: Xoá asks no confirmation"
      expect(row.css("td").last["class"]).to include("text-nowrap", "text-end"), "#{name}: actions are not the last, right-aligned cell"
    end
  end

  it "keeps the user's own account from being deleted from the table, but not the reset link" do
    sign_in admin
    get admin_users_path
    follow_redirect!
    rows = Nokogiri::HTML(response.body).css("tbody tr")
    mine = rows.find { |tr| tr.text.include?(admin.email) }

    expect(mine.css("button").map { |button| button.text.strip }).to include("Gửi link đặt lại mật khẩu")
    expect(mine.css("button").map { |button| button.text.strip }).not_to include("Xoá")
  end

  it "shows no actions to someone who cannot manage the table" do
    sign_in create(:user, :viewer)

    %w[merchants dealers card_types remitters telegram_chats].each do |resource|
      next unless respond_to?("admin_#{resource}_path")

      get public_send("admin_#{resource}_path")
      next unless response.status == 200

      body = Nokogiri::HTML(response.body)
      expect(body.css("tbody .row-actions")).to be_empty, "#{resource}: viewer sees the action menu"
      expect(body.css("tbody a", text: "Sửa")).to be_empty, "#{resource}: viewer sees Sửa"
      expect(body.css("tbody button", text: "Xoá")).to be_empty, "#{resource}: viewer sees Xoá"
    end
  end
end
