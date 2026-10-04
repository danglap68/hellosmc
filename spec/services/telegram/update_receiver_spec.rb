require "rails_helper"

RSpec.describe Telegram::UpdateReceiver do
  let(:update) { telegram_fixture("photo_update") }

  it "registers unknown chats as inactive and does not process their images" do
    result = described_class.call(update)

    chat = TelegramChat.find_by!(telegram_chat_id: -1001234567890)
    expect(chat).not_to be_active
    expect(chat.name).to eq("Anh Trân - Bill")
    expect(result.status).to eq(:ignored_inactive_chat)
    expect(result.telegram_message).to be_processing_ignored
    expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
  end

  context "with an active chat" do
    let!(:chat) { create(:telegram_chat, telegram_chat_id: -1001234567890, active: true) }

    it "persists the message and enqueues the download" do
      result = described_class.call(update)

      message = result.telegram_message
      expect(result.status).to eq(:queued)
      expect(message.telegram_message_id).to eq(77)
      expect(message.message_text).to eq("MB")
      expect(message.sender_name).to eq("Lan Nguyễn")
      expect(message.raw_payload).to eq(update)
      expect(DownloadTelegramAttachmentJob).to have_been_enqueued.with(message.id)
    end

    it "is idempotent for the same chat and message id" do
      described_class.call(update)
      expect { described_class.call(update) }.not_to change(TelegramMessage, :count)
      expect(described_class.call(update).status).to eq(:duplicate)
      expect(DownloadTelegramAttachmentJob).to have_been_enqueued.once
    end

    it "stores text-only messages without enqueuing anything" do
      text_update = { "update_id" => 1, "message" => { "message_id" => 5, "chat" => { "id" => chat.telegram_chat_id, "type" => "group" },
                                                       "date" => Time.current.to_i, "text" => "xin chào" } }
      expect(described_class.call(text_update).status).to eq(:stored_text)
      expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
    end

    it "records edits without re-downloading, keeping the original payload" do
      described_class.call(update)
      edit = { "update_id" => 900002, "edited_message" => update["message"].merge("caption" => "Napas") }

      expect(described_class.call(edit).status).to eq(:edit_recorded)
      message = TelegramMessage.last
      expect(message.message_text).to eq("Napas")
      expect(message.raw_payload.dig("message", "caption")).to eq("MB")
      expect(message.raw_payload["edits"].first["text"]).to eq("Napas")
      log = AuditLog.find_by!(action: "telegram_message.edited")
      expect(log.before_data["message_text"]).to eq("MB")
      expect(DownloadTelegramAttachmentJob).to have_been_enqueued.once
    end
  end

  it "ignores updates without a message" do
    expect(described_class.call({ "update_id" => 3, "my_chat_member" => {} }).status).to eq(:ignored_no_message)
  end
end
