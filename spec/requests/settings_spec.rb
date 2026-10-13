require "rails_helper"
require "aws-sdk-s3"

RSpec.describe "Settings" do
  include_context "accounting setup"

  context "as an admin" do
    before { sign_in create(:user, :admin) }

    it "shows the client's switches, the services and an editable technical table (S1, S4)" do
      get admin_settings_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Tự động kích hoạt nhóm Telegram mới", "Bật xử lý người chuyển tiền",
                                       "Kết nối dịch vụ", "OPENAI_API_KEY")
      expect(response.body).not_to include("test-openai-key", %(name="settings[ocr_auto_approve_threshold]"))
      expect(response.body).to include("Thông số kỹ thuật", "OCR_AUTO_APPROVE_THRESHOLD", "Mặc định",
                                       %(name="tuning[ocr_auto_approve_threshold]"))
    end

    describe "technical tuning" do
      it "saves a value that wins over the environment variable, and audits it" do
        ENV["DUPLICATE_WINDOW_MINUTES"] = "20"

        patch tuning_admin_settings_path, params: { tuning: { "duplicate_window_minutes" => " 30 ", "vision_provider" => "gemini" } }

        expect(response).to redirect_to(admin_settings_path(anchor: "tinh-chinh"))
        expect(AppConfig.tuning("duplicate_window_minutes")).to eq([ 30, :stored ])
        expect(AppConfig.vision_provider).to eq("gemini")
        log = AuditLog.find_by!(action: "settings.tuning_updated")
        expect(log.before_data).to eq("duplicate_window_minutes" => nil, "vision_provider" => nil)
        expect(log.after_data).to eq("duplicate_window_minutes" => "30", "vision_provider" => "gemini")
      end

      it "falls back to the environment variable, then the default, when the field is cleared" do
        AppSetting.create!(key: "duplicate_window_minutes", value: "30")
        AppSetting.insert!({ key: "openai_vision_model", value: "gpt-4.1", created_at: Time.current, updated_at: Time.current })
        AppSetting.create!(key: "primary_vision_model", value: "gpt-5")
        ENV["DUPLICATE_WINDOW_MINUTES"] = "20"

        patch tuning_admin_settings_path, params: { tuning: { "duplicate_window_minutes" => "", "primary_vision_model" => "" } }

        expect(AppConfig.tuning("duplicate_window_minutes")).to eq([ 20, :env ])
        expect(AppConfig.tuning("primary_vision_model")).to eq([ "gpt-6-luna", :default ])
      end

      it "rejects invalid or out-of-range values and saves nothing" do
        patch tuning_admin_settings_path, params: { tuning: { "ocr_auto_approve_threshold" => "1.5", "max_ocr_attempts" => "9",
                                                              "vision_provider" => "nope", "duplicate_window_minutes" => "15" } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Ngưỡng tự động duyệt", "phải trong khoảng 1 – 3")
        expect(AppSetting.where(key: AppConfig::TUNING.keys)).to be_empty
      end
    end

    it "warns plainly when OCR cannot work" do
      ENV.delete("OPENAI_API_KEY")
      get admin_settings_path
      expect(response.body).to include("vui lòng liên hệ kỹ thuật")
    end

    it "saves a switch, which immediately changes processing" do
      patch admin_settings_path, params: { settings: SettingsForm.new.values.merge("telegram_auto_activate_chats" => "1") }
      expect(response).to redirect_to(admin_settings_path)
      expect(flash[:notice]).to eq("Đã lưu cài đặt.")
      expect(AppConfig.telegram_auto_activate_chats?).to be(true)
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

    describe "Telegram connection" do
      let(:client) { instance_double(Telegram::BotClient) }
      let(:token) { "987654:NEW-TOKEN" }

      before do
        allow(Telegram::BotClient).to receive(:new).and_return(client)
        ENV["APP_HOST"] = "bill.example.com"
      end

      it "stores a token Telegram accepts, encrypted and never logged" do
        allow(client).to receive(:get_me).and_return("username" => "smc_bot")

        patch telegram_token_admin_settings_path, params: { telegram_bot_token: " #{token} " }

        expect(response).to redirect_to(admin_settings_path)
        expect(flash[:notice]).to eq("Đã lưu token của bot @smc_bot.")
        expect(AppConfig.telegram_bot_token).to eq(token)
        expect(AppSecret.connection.select_value("SELECT value FROM app_secrets")).not_to include(token)
        expect(AuditLog.last.action).to eq("telegram.token_updated")
        expect(AuditLog.last.attributes.to_json).not_to include(token)
      end

      it "keeps the current token when Telegram rejects the new one" do
        allow(client).to receive(:get_me).and_raise(Telegram::BotClient::Error, "Unauthorized")

        patch telegram_token_admin_settings_path, params: { telegram_bot_token: token }

        expect(flash[:alert]).to include("Telegram không chấp nhận token này", "Unauthorized")
        expect(AppSecret.get("telegram_bot_token")).to be_nil
      end

      it "registers the webhook right after saving the token on the production server" do
        allow(Rails.env).to receive(:production?).and_return(true)
        allow(client).to receive(:get_me).and_return("username" => "smc_bot")
        expect(client).to receive(:set_webhook)
          .with(url: "https://bill.example.com/webhooks/telegram", secret_token: a_string_matching(/\A\h{64}\z/))

        patch telegram_token_admin_settings_path, params: { telegram_bot_token: token }

        expect(flash[:notice]).to include("@smc_bot", "Đã kết nối webhook https://bill.example.com/webhooks/telegram")
        expect(AppConfig.telegram_webhook_secret).to match(/\A\h{64}\z/)
      end

      it "registers the webhook with a new secret and keeps the old one if Telegram refuses" do
        AppSecret.set!("telegram_webhook_secret", "old-secret")
        allow(client).to receive(:set_webhook).and_raise(Telegram::BotClient::Error, "bad webhook")

        post telegram_webhook_admin_settings_path
        expect(flash[:alert]).to include("Không kết nối được webhook", "bad webhook")
        expect(AppConfig.telegram_webhook_secret).to eq("old-secret")

        allow(client).to receive(:set_webhook)
        post telegram_webhook_admin_settings_path
        expect(flash[:notice]).to eq("Đã kết nối webhook https://bill.example.com/webhooks/telegram.")
        expect(AppConfig.telegram_webhook_secret).not_to eq("old-secret")
        expect(AuditLog.last.metadata).to eq("url" => "https://bill.example.com/webhooks/telegram")
      end
    end
  end

  describe "Google Sheet connection" do
    let(:sheet_id) { "1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-aBc" }
    let(:sheet) { instance_double(Workbook::GoogleSheetClient, titles: [ "DS MB", "thu chi" ]) }

    before do
      sign_in create(:user, :admin)
      ENV["GOOGLE_SHEETS_CREDENTIALS_PATH"] = "/tmp/credentials.json"
      allow(Workbook::GoogleSheetClient).to receive(:new).and_return(sheet)
    end

    it "shows the bot token and the sheet on one Kết nối card" do
      get admin_settings_path
      expect(response.body).to include("Kết nối", "Token bot", "Google Sheet Hello SMC", %(name="spreadsheet_id"),
                                       %(name="telegram_bot_token"))
    end

    it "stores the ID after the sheet opens, and bill writes use it right away" do
      patch spreadsheet_admin_settings_path, params: { spreadsheet_id: " #{sheet_id} " }

      expect(response).to redirect_to(admin_settings_path)
      expect(flash[:notice]).to eq("Đã lưu Google Sheet (mở được, 2 tab). Bill mới sẽ ghi vào sheet này.")
      expect(Workbook::GoogleSheetClient).to have_received(:new).with(spreadsheet_id: sheet_id)
      expect(AppConfig.hello_smc_spreadsheet_id).to eq(sheet_id)
      log = AuditLog.find_by!(action: "settings.spreadsheet_updated")
      expect(log.after_data).to eq("hello_smc_spreadsheet_id" => sheet_id)
    end

    it "takes the ID out of the address copied from the browser" do
      patch spreadsheet_admin_settings_path, params: { spreadsheet_id: "https://docs.google.com/spreadsheets/d/#{sheet_id}/edit#gid=0" }

      expect(AppConfig.hello_smc_spreadsheet_id).to eq(sheet_id)
    end

    it "prefers the value saved here over the environment" do
      ENV["HELLO_SMC_SPREADSHEET_ID"] = "ENV_SHEET_ID_THAT_IS_LONG_ENOUGH"
      expect(AppConfig.hello_smc_spreadsheet_id).to eq("ENV_SHEET_ID_THAT_IS_LONG_ENOUGH")

      patch spreadsheet_admin_settings_path, params: { spreadsheet_id: sheet_id }

      expect(AppConfig.hello_smc_spreadsheet_id).to eq(sheet_id)
    end

    it "keeps the current sheet when the new one cannot be opened" do
      AppSetting.create!(key: "hello_smc_spreadsheet_id", value: "CURRENT_SHEET_ID_THAT_IS_LONG_ENOUGH")
      allow(sheet).to receive(:titles).and_raise(StandardError, "The caller does not have permission")

      patch spreadsheet_admin_settings_path, params: { spreadsheet_id: sheet_id }

      expect(flash[:alert]).to include("Không mở được Google Sheet này", "does not have permission")
      expect(AppConfig.hello_smc_spreadsheet_id).to eq("CURRENT_SHEET_ID_THAT_IS_LONG_ENOUGH")
      expect(AuditLog.where(action: "settings.spreadsheet_updated")).to be_empty
    end

    it "rejects text that is not a sheet ID without calling Google" do
      patch spreadsheet_admin_settings_path, params: { spreadsheet_id: "hello world" }

      expect(flash[:alert]).to include("Không đọc được Spreadsheet ID")
      expect(Workbook::GoogleSheetClient).not_to have_received(:new)
    end

    it "saves without a check when the server has no Google account (local)" do
      ENV.delete("GOOGLE_SHEETS_CREDENTIALS_PATH")
      ENV.delete("GOOGLE_SHEETS_CREDENTIALS_JSON")

      patch spreadsheet_admin_settings_path, params: { spreadsheet_id: sheet_id }

      expect(flash[:notice]).to include("Chưa kiểm tra được")
      expect(AppConfig.hello_smc_spreadsheet_id).to eq(sheet_id)
    end
  end

  it "is admin-only" do
    # Check the real stored value: spec/support/remitter_feature_flag.rb stubs
    # the flag on for the full-flow examples.
    allow(AppConfig).to receive(:remitter_features_enabled?).and_call_original
    sign_in create(:user, :operator)
    patch admin_settings_path, params: { settings: { "remitter_features_enabled" => "1" } }
    expect(response).to have_http_status(:forbidden)
    expect(AppConfig.remitter_features_enabled?).to be(false)

    expect(R2Check).not_to receive(:call)
    post check_r2_admin_settings_path
    expect(response).to have_http_status(:forbidden)

    patch telegram_token_admin_settings_path, params: { telegram_bot_token: "1:X" }
    expect(response).to have_http_status(:forbidden)
    post telegram_webhook_admin_settings_path
    expect(response).to have_http_status(:forbidden)
    expect(AppSecret.count).to eq(0)

    patch spreadsheet_admin_settings_path, params: { spreadsheet_id: "1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-aBc" }
    expect(response).to have_http_status(:forbidden)
    expect(AppSetting.where(key: "hello_smc_spreadsheet_id")).to be_empty

    patch tuning_admin_settings_path, params: { tuning: { "duplicate_window_minutes" => "30" } }
    expect(response).to have_http_status(:forbidden)
    expect(AppSetting.where(key: "duplicate_window_minutes")).to be_empty
  end
end
