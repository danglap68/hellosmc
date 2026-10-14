require "rails_helper"

RSpec.describe Telegram::UpdateReceiver do
  it "routes payment callbacks through an after-commit job instead of photo processing" do
    callback = { "id" => "query1", "data" => "pqr:confirm:abc", "from" => { "id" => 123 } }
    expect { described_class.call({ "update_id" => 987654, "callback_query" => callback }) }
      .to have_enqueued_job(ProcessPaymentQrCallbackJob).with(callback)
    expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
  end
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
      expect(message.edited_at).to be_present
      log = AuditLog.find_by!(action: "telegram_message.edited")
      expect(log.before_data["message_text"]).to eq("MB")
      expect(DownloadTelegramAttachmentJob).to have_been_enqueued.once
    end

    it "collects media-group images into an album" do
      album_update = { "update_id" => 900010, "message" => update["message"].merge("media_group_id" => "mg-1") }
      described_class.call(album_update)

      album = BillAlbum.find_by!(telegram_chat: chat, media_group_id: "mg-1")
      expect(album.metadata["message_ids"]).to be_present
    end

    it "stores a voice message without downloading it" do
      voice = { "update_id" => 15, "message" => { "message_id" => 16, "chat" => { "id" => chat.telegram_chat_id, "type" => "group" },
                                                  "date" => Time.current.to_i, "voice" => { "file_id" => "v", "duration" => 3 } } }
      result = described_class.call(voice)
      expect(result.status).to eq(:stored_text)
      expect(result.telegram_message.kind).to eq("voice")
      expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
    end

    it "stores a reply and a forward" do
      payload = { "update_id" => 16, "message" => { "message_id" => 17, "chat" => { "id" => chat.telegram_chat_id, "type" => "group" },
                                                    "date" => Time.current.to_i, "text" => "ok",
                                                    "reply_to_message" => { "message_id" => 3 },
                                                    "forward_sender_name" => "Ẩn danh" } }
      message = described_class.call(payload).telegram_message
      expect(message.reply_to_message_id).to eq(3)
      expect(message.forwarded_from).to eq("Ẩn danh")
    end

    it "downloads an edited photo whose original was never stored" do
      edit = { "update_id" => 18, "edited_message" => update["message"].merge("edit_date" => Time.current.to_i) }
      result = described_class.call(edit)
      expect(result.status).to eq(:queued)
      expect(result.telegram_message.edited_at).to be_present
      expect(AuditLog.where(action: "telegram_message.created_from_edit")).to exist
      expect(DownloadTelegramAttachmentJob).to have_been_enqueued.once
    end
  end

  it "stores text from an inactive chat and does not download it" do
    text = { "update_id" => 19, "message" => { "message_id" => 20,
                                               "chat" => { "id" => -1001234567890, "type" => "group", "title" => "Anh Trân - Bill" },
                                               "date" => Time.current.to_i, "text" => "nhóm tắt" } }
    result = described_class.call(text)
    expect(result.status).to eq(:ignored_inactive_chat)
    expect(result.telegram_message).to be_processing_ignored
    expect(result.telegram_message.message_text).to eq("nhóm tắt")
    expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
  end

  it "ignores updates without a message" do
    expect(described_class.call({ "update_id" => 3, "my_chat_member" => {} }).status).to eq(:ignored_no_message)
  end
end
