require "rails_helper"

RSpec.describe Telegram::StuckDownloads do
  let(:chat) { create(:telegram_chat, active: true) }

  def queued_photo(**attributes)
    create(:telegram_message, telegram_chat: chat, processing_status: "queued",
                              raw_payload: telegram_fixture("photo_update"), updated_at: 6.minutes.ago, **attributes)
  end

  it "previews only stale queued photos without changing records or enqueuing work" do
    stuck = queued_photo
    queued_photo(updated_at: Time.current)
    queued_photo(processing_status: "failed")
    queued_photo(processing_status: "ignored")
    queued_photo(telegram_chat: create(:telegram_chat, active: false))
    queued_photo(raw_payload: { "message" => { "text" => "hi" } })
    stored = queued_photo
    create(:bill_image, telegram_message: stored)

    expect(described_class.call).to eq(1)
    expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
    expect(stuck.reload.updated_at).to eq(6.minutes.ago)
  end

  it "re-enqueues missing downloads and avoids repeatedly scheduling the same stale row" do
    stuck = queued_photo

    expect(described_class.call(apply: true)).to eq(1)
    expect(DownloadTelegramAttachmentJob).to have_been_enqueued.with(stuck.id)
    expect(described_class.call(apply: true)).to eq(0)
    expect(stuck.reload).to be_processing_queued
  end
end
