require "rails_helper"

RSpec.describe TelegramChat do
  it "requires a unique numeric chat id" do
    create(:telegram_chat, telegram_chat_id: -100_123)
    expect(build(:telegram_chat, telegram_chat_id: -100_123)).not_to be_valid
    expect(build(:telegram_chat, telegram_chat_id: "abc")).not_to be_valid
  end

  it "shows its name, or its id when it has none" do
    expect(build(:telegram_chat, name: "Bill Chương").display_name).to eq("Bill Chương")
    expect(build(:telegram_chat, name: nil, telegram_chat_id: -100_999).display_name).to eq("-100999")
  end

  it "needs no HKD or agent: those are read from the bill" do
    expect(described_class.reflect_on_association(:merchants)).to be_nil
    expect(described_class.new).not_to respond_to(:group_dealer)
  end
end
