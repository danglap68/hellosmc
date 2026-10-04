require "rails_helper"
require "aws-sdk-s3"

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

    it "reports a working R2 connection" do
      steps = R2Check::STEPS.map { |name| R2Check::Step.new(name: name, error: nil) }
      allow(R2Check).to receive(:call).and_return(R2Check::Result.new(steps: steps, duration_ms: 120))

      post check_r2_admin_settings_path
      expect(response).to redirect_to(admin_settings_path)
      expect(flash[:notice]).to include("Kết nối Cloudflare R2 hoạt động", "120 ms")
    end

    it "explains which R2 step failed and why" do
      error = Aws::S3::Errors::SignatureDoesNotMatch.new(nil, "signature mismatch")
      steps = [ R2Check::Step.new(name: :configuration, error: nil), R2Check::Step.new(name: :upload, error: error) ]
      allow(R2Check).to receive(:call).and_return(R2Check::Result.new(steps: steps, duration_ms: 50))

      post check_r2_admin_settings_path
      expect(flash[:alert]).to include("Ghi file", "R2_SECRET_ACCESS_KEY không đúng", "signature mismatch")
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

    expect(R2Check).not_to receive(:call)
    post check_r2_admin_settings_path
    expect(response).to have_http_status(:forbidden)
  end
end
