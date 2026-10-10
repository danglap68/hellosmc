require "rails_helper"

RSpec.describe BillAlbum do
  let(:chat) { create(:telegram_chat) }
  let(:album) { create(:bill_album, telegram_chat: chat) }

  it "requires a unique media_group_id per chat" do
    create(:bill_album, telegram_chat: chat, media_group_id: "mg-1")
    duplicate = build(:bill_album, telegram_chat: chat, media_group_id: "mg-1")
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:media_group_id]).to be_present
  end

  it "allows the same media_group_id in different chats" do
    create(:bill_album, telegram_chat: chat, media_group_id: "mg-1")
    other = build(:bill_album, media_group_id: "mg-1")
    expect(other).to be_valid
  end

  it "treats only terminal statuses as terminal" do
    expect(album).not_to be_terminal
    %w[reconciled needs_review skipped failed].each do |status|
      album.update!(status: status)
      expect(album).to be_terminal
    end
  end

  it "detects messages that still need an image" do
    create(:telegram_message, telegram_chat: chat, media_group_id: album.media_group_id,
                              processing_status: "queued")
    expect(album.messages_without_images?).to be(true)
  end

  it "ignores failed messages when checking for pending images" do
    create(:telegram_message, telegram_chat: chat, media_group_id: album.media_group_id,
                              processing_status: "failed")
    expect(album.messages_without_images?).to be(false)
  end

  it "detects images still being OCR'd" do
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        ocr_status: "processing")
    expect(album.images_pending_ocr?).to be(true)
  end

  it "detects an OCR failure" do
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        ocr_status: "failed")
    expect(album.any_ocr_failed?).to be(true)
  end
end
