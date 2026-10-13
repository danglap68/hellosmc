require "rails_helper"

RSpec.describe Telegram::CollectionHealth do
  let(:client) { instance_double(Telegram::BotClient, get_me: { "can_read_all_group_messages" => true }) }

  before { allow(Telegram::BotClient).to receive(:new).and_return(client) }

  def row_for(chat)
    described_class.call.rows.find { |row| row.chat == chat }
  end

  it "counts a gap in message ids inside the last 7 days" do
    chat = create(:telegram_chat, active: true)
    [ 1, 2, 5 ].each { |id| create(:telegram_message, telegram_chat: chat, telegram_message_id: id, sent_at: Time.current) }

    expect(row_for(chat).missing_count).to eq(2)
    expect(described_class.missing_ids(chat)).to eq([ 3, 4 ])
  end

  it "reports no gap for an empty chat, a single message, a continuous range, or messages older than 7 days" do
    empty = create(:telegram_chat, active: false)
    single = create(:telegram_chat)
    create(:telegram_message, telegram_chat: single, telegram_message_id: 8, sent_at: Time.current)
    continuous = create(:telegram_chat)
    [ 3, 4 ].each { |id| create(:telegram_message, telegram_chat: continuous, telegram_message_id: id, sent_at: Time.current) }
    old = create(:telegram_chat)
    [ 1, 4 ].each { |id| create(:telegram_message, telegram_chat: old, telegram_message_id: id, sent_at: 8.days.ago) }

    expect(row_for(empty).missing_count).to eq(0)
    expect(row_for(single).missing_count).to eq(0)
    expect(row_for(continuous).missing_count).to eq(0)
    expect(row_for(old).missing_count).to eq(0)
    expect(described_class.missing_ids(old)).to eq([])
  end

  it "warns when an active chat has been silent for 24 hours, and not when it is off" do
    quiet = create(:telegram_chat, name: "Im", active: true)
    create(:telegram_message, telegram_chat: quiet, sent_at: 25.hours.ago)
    off = create(:telegram_chat, name: "Tắt", active: false)
    recent = create(:telegram_chat, name: "Mới", active: true)
    create(:telegram_message, telegram_chat: recent, sent_at: 1.hour.ago)

    names = described_class.call.silent_rows.map { |row| row.chat.name }
    expect(names).to include("Im")
    expect(names).not_to include("Tắt", "Mới")
  end

  it "warns only when the bot cannot read every group message" do
    allow(client).to receive(:get_me).and_return({ "can_read_all_group_messages" => false })
    expect(described_class.call.privacy_warning).to be(true)

    allow(client).to receive(:get_me).and_return({ "can_read_all_group_messages" => true })
    expect(described_class.call.privacy_warning).to be(false)

    allow(Telegram::BotClient).to receive(:new).and_raise(Telegram::BotClient::Error, "down")
    expect(described_class.call.privacy_warning).to be(false)
  end
end
