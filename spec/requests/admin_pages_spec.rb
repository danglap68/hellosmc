require "rails_helper"

# Smoke test: every admin page renders for an admin, in Vietnamese.
RSpec.describe "Admin pages" do
  include_context "accounting setup"

  let(:admin) { create(:user, :admin) }
  let!(:approved) { Transactions::Builder.call(bill_image: analyzed_bill).sole }
  let!(:review) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }
  let!(:merchant_alias) { create(:merchant_alias, merchant: merchant, alias: "THIEN KIM") }
  let!(:export) { create(:excel_export, generated_by: admin) }

  before { sign_in admin }

  it "renders index, show, new and edit pages" do
    paths = [
      admin_root_path,
      admin_transactions_path, admin_transactions_path(q: "000269", status: "approved", date_from: "2026-10-01"),
      admin_transaction_path(approved), admin_transaction_path(review), edit_admin_transaction_path(review),
      admin_reviews_path, admin_reviews_path(queue: "hold"), admin_review_path(review), admin_review_path(approved),
      new_admin_bill_upload_path,
      admin_dealers_path, admin_dealer_path(dealer), new_admin_dealer_path, edit_admin_dealer_path(dealer),
      admin_telegram_chats_path, admin_telegram_chats_path(filter: "unmapped"), admin_telegram_chat_path(chat),
      new_admin_telegram_chat_path, edit_admin_telegram_chat_path(chat),
      admin_merchants_path, admin_merchant_path(merchant), new_admin_merchant_path, edit_admin_merchant_path(merchant),
      edit_admin_merchant_merchant_alias_path(merchant, merchant_alias),
      admin_fee_rules_path, admin_fee_rules_path(state: "current"), admin_fee_rule_path(default_rule),
      new_admin_fee_rule_path, edit_admin_fee_rule_path(default_rule),
      admin_card_types_path, new_admin_card_type_path, edit_admin_card_type_path(mb_card),
      admin_excel_exports_path, new_admin_excel_export_path, admin_excel_export_path(export),
      admin_audit_logs_path, admin_audit_logs_path(actor: "system"), admin_audit_log_path(AuditLog.first),
      admin_users_path, new_admin_user_path, edit_admin_user_path(admin),
      admin_settings_path
    ]

    paths.each do |path|
      get path
      expect(response).to have_http_status(:ok), "#{path} returned #{response.status}"
      expect(response.body).not_to include("translation missing"), "#{path} has missing translations"
      expect(response.body).not_to match(/Translation missing/i), "#{path} has missing translations"
    end
  end

  it "serves bill images only to signed-in users" do
    get admin_bill_image_path(approved.bill_image)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/jpeg")

    sign_out admin
    get admin_bill_image_path(approved.bill_image)
    expect(response).to redirect_to(new_user_session_path)
  end

  it "polls a pending export with Turbo instead of a meta refresh" do
    get admin_excel_export_path(export)
    expect(response.body).to include('data-controller="auto-refresh"')
    expect(response.body).not_to include('http-equiv="refresh"')

    export.update!(status: "completed")
    get admin_excel_export_path(export)
    expect(response.body).not_to include('data-controller="auto-refresh"')
  end

  it "uses Vietnamese labels for statuses" do
    get admin_transactions_path
    expect(response.body).to include("Đã duyệt", "Cần kiểm tra")
  end
end
