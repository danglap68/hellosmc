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
end
