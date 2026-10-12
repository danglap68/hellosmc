require "rails_helper"

RSpec.describe AppSetting do
  it "keeps only the client's switches" do
    expect(described_class::DEFINITIONS.keys).to contain_exactly("telegram_auto_activate_chats", "remitter_features_enabled")
  end

  it "falls back to typed defaults and refreshes after a change" do
    expect(AppConfig.telegram_auto_activate_chats?).to be(false)
    described_class.create!(key: "telegram_auto_activate_chats", value: "true")
    expect(AppConfig.telegram_auto_activate_chats?).to be(true)
  end

  it "rejects keys that are not settings any more" do
    expect(described_class.new(key: "ocr_auto_approve_threshold", value: "0.9")).not_to be_valid
    expect(described_class.new(key: "openai_api_key", value: "sk")).not_to be_valid
  end

  it "never stores secrets" do
    expect(described_class::DEFINITIONS.keys.grep(/key|token|secret|password/)).to be_empty
  end
end
