require "rails_helper"

RSpec.describe "Settings" do
  include_context "accounting setup"

  context "as an admin" do
    before { sign_in create(:user, :admin) }

    it "shows editable settings and which secrets are configured, without revealing them" do
      get admin_settings_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ngưỡng tự động duyệt", "Kết nối dịch vụ", "OPENAI_API_KEY")
      expect(response.body).not_to include("test-openai-key")
    end

    it "updates settings, which immediately change processing" do
      patch admin_settings_path, params: { settings: SettingsForm.new.values.merge("ocr_auto_approve_threshold" => "99") }
      expect(response).to redirect_to(admin_settings_path)
      expect(flash[:notice]).to eq("Đã lưu cài đặt.")

      transaction = Transactions::Builder.call(bill_image: analyzed_bill).sole
      expect(transaction).to be_needs_review
      expect(transaction.review_reason_codes).to include("amount_low_confidence")
    end

    it "re-renders with Vietnamese errors" do
      patch admin_settings_path, params: { settings: SettingsForm.new.values.merge("ocr_review_threshold" => "95") }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("phải nhỏ hơn hoặc bằng ngưỡng tự động duyệt")
    end
  end

  it "is admin-only" do
    sign_in create(:user, :operator)
    patch admin_settings_path, params: { settings: { "duplicate_window_minutes" => "60" } }
    expect(response).to have_http_status(:forbidden)
    expect(AppConfig.duplicate_window_minutes).to eq(10)
  end
end
