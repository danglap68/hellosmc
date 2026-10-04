require "rails_helper"

RSpec.describe SettingsForm do
  let(:admin) { create(:user, :admin) }

  def form(overrides = {})
    described_class.new(described_class.new.values.merge(overrides))
  end

  it "shows rates as percentages" do
    expect(described_class.new["ocr_auto_approve_threshold"]).to eq("92")
    expect(described_class.new["merchant_fuzzy_threshold"]).to eq("88")
  end

  it "stores percentages as exact rates and audits only what changed" do
    expect(form("ocr_auto_approve_threshold" => "95", "duplicate_window_minutes" => "15").save(actor: admin)).to be(true)

    expect(AppConfig.ocr_auto_approve_threshold).to eq(BigDecimal("0.95"))
    expect(AppConfig.duplicate_window_minutes).to eq(15)
    log = AuditLog.find_by!(action: "settings.updated")
    expect(log.actor_user).to eq(admin)
    expect(log.before_data).to eq("ocr_auto_approve_threshold" => "0.92", "duplicate_window_minutes" => "10")
    expect(log.after_data).to eq("ocr_auto_approve_threshold" => "0.95", "duplicate_window_minutes" => "15")
  end

  it "does nothing when nothing changed" do
    expect(form.save(actor: admin)).to be(true)
    expect(AppSetting.count).to eq(0)
    expect(AuditLog.where(action: "settings.updated")).not_to exist
  end

  it "keeps the review threshold at or below the auto-approve threshold" do
    subject = form("ocr_auto_approve_threshold" => "80", "ocr_review_threshold" => "85")
    expect(subject.save(actor: admin)).to be(false)
    expect(subject.errors[:ocr_review_threshold]).to be_present
  end

  it "rejects values out of range or not numbers" do
    subject = form("ocr_auto_approve_threshold" => "120", "duplicate_window_minutes" => "abc", "max_bill_image_mb" => "50")
    expect(subject).not_to be_valid
    expect(subject.errors.attribute_names).to include(:ocr_auto_approve_threshold, :duplicate_window_minutes, :max_bill_image_mb)
  end

  it "refuses a provider whose API key is not configured on the server" do
    subject = form("vision_provider" => "gemini")
    expect(subject).not_to be_valid
    expect(subject.errors.full_messages.join).to include("GEMINI_API_KEY")
  end

  it "still saves other settings while the current provider's key is missing" do
    ENV.delete("OPENAI_API_KEY")
    expect(form("duplicate_window_minutes" => "20").save(actor: admin)).to be(true)
  end

  it "validates the sender email" do
    expect(form("mailer_sender" => "not-an-email")).not_to be_valid
  end
end
