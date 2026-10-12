require "rails_helper"

# Technical tuning: ENV, then a value stored when it was a setting, then the
# default (docs/SPEC_SIMPLIFY_SETTINGS.md §3.2).
RSpec.describe AppConfig do
  # A row kept from when the key was on the settings page (no longer valid to create).
  def legacy(key, value)
    AppSetting.insert!({ key: key, value: value, created_at: Time.current, updated_at: Time.current })
    AppSetting.reset_cache!
  end

  it "uses the defaults (C1)" do
    expect(described_class.vision_provider).to eq("openai")
    expect(described_class.primary_vision_model).to eq("gpt-6-luna")
    expect(described_class.validator_vision_model).to eq("gpt-6.1-sol")
    expect(described_class.vision_validation_enabled?).to be(true)
    expect(described_class.vision_validation_mode).to eq("risk_based")
    expect(described_class.ocr_auto_approve_threshold).to eq(BigDecimal("0.92"))
    expect(described_class.ocr_review_threshold).to eq(BigDecimal("0.70"))
    expect(described_class.duplicate_window_minutes).to eq(10)
    expect(described_class.max_bill_image_bytes).to eq(20.megabytes)
    expect(described_class.hello_smc_spreadsheet_id).to be_nil
    expect(described_class.tuning("ocr_auto_approve_threshold")).to eq([ BigDecimal("0.92"), :default ])
  end

  it "keeps a value stored back when it was a setting, so a deploy changes nothing (C2)" do
    legacy("ocr_auto_approve_threshold", "0.95")
    legacy("hello_smc_spreadsheet_id", "sheet-from-ui")

    expect(described_class.ocr_auto_approve_threshold).to eq(BigDecimal("0.95"))
    expect(described_class.hello_smc_spreadsheet_id).to eq("sheet-from-ui")
    expect(described_class.tuning("ocr_auto_approve_threshold").last).to eq(:stored)
  end

  it "lets an environment variable win (C3)" do
    legacy("ocr_auto_approve_threshold", "0.95")
    ENV["OCR_AUTO_APPROVE_THRESHOLD"] = "0.9"

    expect(described_class.tuning("ocr_auto_approve_threshold")).to eq([ BigDecimal("0.9"), :env ])
  end

  it "honors a legacy primary model choice (C4)" do
    legacy("openai_vision_model", "gpt-4.1")
    expect(described_class.primary_vision_model).to eq("gpt-4.1")
  end

  it "clamps the OCR run budget (C5) and reads sizes (C6)" do
    ENV["OCR_MAX_ATTEMPTS"] = "10"
    ENV["MAX_BILL_IMAGE_MB"] = "5"

    expect(described_class.max_ocr_attempts).to eq(3)
    expect(described_class.max_bill_image_bytes).to eq(5.megabytes)
  end

  it "ignores an invalid value and falls back" do
    ENV["OCR_AUTO_APPROVE_THRESHOLD"] = "abc"
    legacy("duplicate_window_minutes", "15")
    ENV["DUPLICATE_WINDOW_MINUTES"] = "-"

    expect(described_class.ocr_auto_approve_threshold).to eq(BigDecimal("0.92"))
    expect(described_class.duplicate_window_minutes).to eq(15)
  end

  it "never lets the readable threshold exceed the auto-approve one" do
    ENV["OCR_REVIEW_THRESHOLD"] = "0.95"
    expect(described_class.ocr_review_threshold).to eq(BigDecimal("0.92"))
  end
end
