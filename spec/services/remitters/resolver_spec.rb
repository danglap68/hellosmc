require "rails_helper"

RSpec.describe Remitters::Resolver do
  it "resolves by telegram_user_id first" do
    lap = create(:remitter, name: "Lập", telegram_user_id: 123)
    result = described_class.call(telegram_user_id: 123, telegram_username: "someone_else")
    expect(result.remitter).to eq(lap)
    expect(result.source).to eq("telegram_user_id")
  end

  it "resolves by telegram_username, case-insensitive and ignoring the @ prefix" do
    lap = create(:remitter, name: "Lập", telegram_username: "lap")
    result = described_class.call(telegram_user_id: nil, telegram_username: "@Lap")
    expect(result.remitter).to eq(lap)
    expect(result.source).to eq("telegram_username")
  end

  it "returns a nil remitter when nothing matches" do
    result = described_class.call(telegram_user_id: 999, telegram_username: "unknown")
    expect(result.remitter).to be_nil
    expect(result.source).to be_nil
  end

  it "ignores inactive remitters" do
    create(:remitter, name: "Lập", telegram_user_id: 123, active: false)
    expect(described_class.call(telegram_user_id: 123).remitter).to be_nil
  end

  it "refuses a matching username owned by a different pinned Telegram ID" do
    create(:remitter, telegram_user_id: 123, telegram_username: "old_handle")
    [ nil, 999 ].each do |incoming_id|
      result = described_class.call(telegram_user_id: incoming_id, telegram_username: "@Old_Handle")
      expect(result.remitter).to be_nil
      expect(result.source).to be_nil
    end
  end

  it "keeps ID matches working after a username changes and supports username-only configuration" do
    pinned = create(:remitter, telegram_user_id: 123, telegram_username: "old_handle")
    legacy = create(:remitter, telegram_username: "legacy_handle")
    expect(described_class.call(telegram_user_id: 123, telegram_username: "new_handle").remitter).to eq(pinned)
    expect(described_class.call(telegram_user_id: 999, telegram_username: "legacy_handle").remitter).to eq(legacy)
  end
end
