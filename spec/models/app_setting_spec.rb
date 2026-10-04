require "rails_helper"

RSpec.describe AppSetting do
  it "falls back to typed defaults" do
    expect(described_class.get("ocr_auto_approve_threshold")).to eq(BigDecimal("0.92"))
    expect(described_class.get("duplicate_window_minutes")).to eq(10)
    expect(described_class.get("telegram_auto_activate_chats")).to be(false)
    expect(described_class.get("vision_provider")).to eq("openai")
    expect(AppConfig.primary_vision_model).to eq("gpt-6-luna")
    expect(AppConfig.validator_vision_model).to eq("gpt-6.1-sol")
    expect(AppConfig.vision_validation_enabled?).to be(true)
    expect(AppConfig.vision_validation_mode).to eq("risk_based")
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

  it "honors legacy primary choices until the new primary setting is explicitly stored" do
    described_class.create!(key: "openai_vision_model", value: "gpt-4.1")
    expect(AppConfig.primary_vision_model).to eq("gpt-4.1")
    described_class.create!(key: "primary_vision_model", value: "gpt-6-luna")
    expect(AppConfig.primary_vision_model).to eq("gpt-6-luna")
  end

  it "clamps legacy stored retry budgets to the hard ceiling" do
    described_class.create!(key: "max_ocr_attempts", value: "10")
    expect(AppConfig.max_ocr_attempts).to eq(3)
  end
end
