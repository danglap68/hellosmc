require "rails_helper"

RSpec.describe ProcessTelegramUpdateJob do
  let(:update) { telegram_fixture("photo_update") }

  it "still accepts a raw update hash from a job queued before the inbox existed" do
    described_class.perform_now(update)
    expect(TelegramMessage.count).to eq(1)
    expect(TelegramMessage.last.kind).to eq("photo")
  end

  it "processes an inbox row once" do
    inbox = TelegramUpdate.create!(update_id: update["update_id"], payload: update, received_at: Time.current)
    described_class.perform_now(inbox.id)
    expect(inbox.reload).to be_processed
    described_class.perform_now(inbox.id)
    expect(TelegramMessage.count).to eq(1)
  end

  it "records a failure and lets the job retry" do
    inbox = TelegramUpdate.create!(update_id: 7, payload: { "update_id" => 7 }, received_at: Time.current)
    allow(Telegram::UpdateReceiver).to receive(:call).and_raise(RuntimeError, "boom")

    expect { described_class.perform_now(inbox.id) }.to raise_error(RuntimeError, "boom")
    expect(inbox.reload).to have_attributes(status: "failed", attempts: 1)
  end

  it "does not expose a download job until the transaction that creates the message commits" do
    create(:telegram_chat, telegram_chat_id: update.dig("message", "chat", "id"), active: true)
    message = nil

    ActiveRecord::Base.transaction(requires_new: true) do
      message = Telegram::UpdateReceiver.call(update).telegram_message
      expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
    end

    expect(DownloadTelegramAttachmentJob).to have_been_enqueued.with(message.id)
  end

  it "never enqueues a download for a rolled-back message" do
    create(:telegram_chat, telegram_chat_id: update.dig("message", "chat", "id"), active: true)

    ActiveRecord::Base.transaction(requires_new: true) do
      Telegram::UpdateReceiver.call(update)
      raise ActiveRecord::Rollback
    end

    expect(TelegramMessage.count).to eq(0)
    expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
  end
end

RSpec.describe RetryStuckTelegramUpdatesJob do
  it "re-enqueues a stale row, skips a fresh or exhausted one, and drops old processed copies" do
    stale = TelegramUpdate.create!(update_id: 1, payload: { "update_id" => 1 }, received_at: Time.current)
    stale.update_columns(updated_at: 6.minutes.ago)
    fresh = TelegramUpdate.create!(update_id: 2, payload: { "update_id" => 2 }, received_at: Time.current)
    exhausted = TelegramUpdate.create!(update_id: 3, payload: { "update_id" => 3 }, status: "failed", attempts: 5, received_at: Time.current)
    exhausted.update_columns(updated_at: 6.minutes.ago)
    old = TelegramUpdate.create!(update_id: 4, payload: { "update_id" => 4 }, status: "processed", received_at: Time.current)
    old.update_columns(processed_at: 15.days.ago)

    described_class.perform_now

    expect(ProcessTelegramUpdateJob).to have_been_enqueued.with(stale.id)
    expect(ProcessTelegramUpdateJob).not_to have_been_enqueued.with(fresh.id)
    expect(ProcessTelegramUpdateJob).not_to have_been_enqueued.with(exhausted.id)
    expect(TelegramUpdate.where(id: old.id)).not_to exist
  end
end
