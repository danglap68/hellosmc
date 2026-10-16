require "rails_helper"

RSpec.describe AppSetting do
  it "keeps only the client's switches" do
    expect(described_class::DEFINITIONS.keys).to contain_exactly("telegram_auto_activate_chats", "remitter_features_enabled",
                                                              "ds_header_auto_switch", "payment_qr_telegram_enabled",
                                                              "payment_qr_bot_username")
  end

  it "turns the DS MB header auto switch on by default" do
    expect(AppConfig.ds_header_auto_switch?).to be(true)
    described_class.create!(key: "ds_header_auto_switch", value: "false")
    expect(AppConfig.ds_header_auto_switch?).to be(false)
  end

  it "falls back to typed defaults and refreshes after a change" do
    expect(AppConfig.telegram_auto_activate_chats?).to be(false)
    described_class.create!(key: "telegram_auto_activate_chats", value: "true")
    expect(AppConfig.telegram_auto_activate_chats?).to be(true)
  end

  it "accepts technical tuning keys and rejects unknown ones" do
    expect(described_class.new(key: "ocr_auto_approve_threshold", value: "0.9")).to be_valid
    expect(described_class.new(key: "openai_vision_model", value: "gpt-4.1")).not_to be_valid
    expect(described_class.new(key: "openai_api_key", value: "sk")).not_to be_valid
  end

  it "never stores secrets" do
    expect(described_class::DEFINITIONS.keys.grep(/key|token|secret|password/)).to be_empty
  end
end
