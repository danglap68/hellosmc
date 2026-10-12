require "rails_helper"

RSpec.describe SettingsForm do
  let(:admin) { create(:user, :admin) }

  def form(overrides = {})
    described_class.new(described_class.new.values.merge(overrides))
  end

  it "holds only the client's switches" do
    expect(described_class.new.values).to eq("telegram_auto_activate_chats" => "0", "remitter_features_enabled" => "0")
  end

  it "saves a switch and audits only what changed (S2)" do
    expect(form("remitter_features_enabled" => "1").save(actor: admin)).to be(true)

    expect(AppConfig.remitter_features_enabled?).to be(true)
    log = AuditLog.find_by!(action: "settings.updated")
    expect(log.actor_user).to eq(admin)
    expect(log.before_data).to eq("remitter_features_enabled" => "false")
    expect(log.after_data).to eq("remitter_features_enabled" => "true")
  end

  it "does nothing when nothing changed" do
    expect(form.save(actor: admin)).to be(true)
    expect(AppSetting.count).to eq(0)
    expect(AuditLog.where(action: "settings.updated")).not_to exist
  end

  it "ignores keys that are not settings any more (S3)" do
    expect(form("ocr_auto_approve_threshold" => "50").save(actor: admin)).to be(true)

    expect(AppSetting.count).to eq(0)
    expect(AppConfig.ocr_auto_approve_threshold).to eq(BigDecimal("0.92"))
  end
end
