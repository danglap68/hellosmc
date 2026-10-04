require "rails_helper"

RSpec.describe AppSetting do
  it "falls back to typed defaults" do
    expect(described_class.get("ocr_auto_approve_threshold")).to eq(BigDecimal("0.92"))
    expect(described_class.get("duplicate_window_minutes")).to eq(10)
    expect(described_class.get("telegram_auto_activate_chats")).to be(false)
    expect(described_class.get("vision_provider")).to eq("openai")
  end

  it "returns stored values and refreshes after a change" do
    expect(AppConfig.max_bill_image_bytes).to eq(20.megabytes)
    described_class.create!(key: "max_bill_image_mb", value: "5")
    expect(AppConfig.max_bill_image_bytes).to eq(5.megabytes)
  end

  it "rejects unknown keys" do
    expect(described_class.new(key: "openai_api_key", value: "sk")).not_to be_valid
  end

  it "never stores secrets" do
    expect(described_class::DEFINITIONS.keys.grep(/key|token|secret|password/)).to be_empty
  end
end
