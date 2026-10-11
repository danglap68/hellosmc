require "rails_helper"

RSpec.describe "Telegram groups" do
  include_context "accounting setup"

  let!(:inactive) { create(:telegram_chat, telegram_chat_id: -1001234567890, active: false) }

  before do
    Telegram::UpdateReceiver.call(telegram_fixture("photo_update"))
    sign_in create(:user, :admin)
  end

  it "keeps images sent while inactive and processes them once the group is mapped and active" do
    expect(inactive.telegram_messages.stored_unprocessed_images.count).to eq(1)

    post process_stored_admin_telegram_chat_path(inactive)
    expect(flash[:alert]).to be_present
    expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued

    inactive.update!(active: true, merchants: [ merchant ])
    get admin_telegram_chat_path(inactive)
    expect(response.body).to include("Có 1 ảnh được gửi khi nhóm chưa hoạt động")

    post process_stored_admin_telegram_chat_path(inactive)
    expect(DownloadTelegramAttachmentJob).to have_been_enqueued.once
    expect(inactive.telegram_messages.first).to be_processing_queued
    expect(AuditLog.where(action: "telegram_chat.stored_images_processed")).to exist
  end

  it "saves several HKDs for a group" do
    other = create(:merchant)
    patch admin_telegram_chat_path(inactive), params: { telegram_chat: { merchant_ids: [ "", merchant.id.to_s, other.id.to_s ] } }
    expect(inactive.reload.merchants).to contain_exactly(merchant, other)
  end

  it "shows the agent read from the group title" do
    inactive.update!(name: "Anh Trân-Thiên Kim GV")
    get admin_telegram_chat_path(inactive)
    expect(response.body).to include("Anh Trân")
  end

  it "renders the multi-HKD picker on the edit form" do
    get edit_admin_telegram_chat_path(inactive)
    expect(response.body).to include("telegram_chat[merchant_ids][]")
    expect(response.body).to include(merchant.name)
  end
end
