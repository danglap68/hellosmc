require "rails_helper"

# A photo from a remitter becomes a RemitterTransfer (never a transaction).
RSpec.describe Telegram::UpdateReceiver, "remitter transfers" do
  let(:update) { telegram_fixture("photo_update") } # sender id 4242, caption "MB"
  let!(:chat) { create(:telegram_chat, telegram_chat_id: -1001234567890, active: true) }

  before do
    allow(AppConfig).to receive(:remitter_features_enabled?).and_return(true)
    Workbook::Seed.call
  end

  it "routes a remitter matched by Telegram user id to the transfer flow" do
    lap = create(:remitter, name: "Lập", telegram_user_id: 4242)

    result = described_class.call(update)

    expect(result.status).to eq(:queued_remitter_transfer)
    transfer = RemitterTransfer.sole
    expect(transfer.remitter).to eq(lap)
    expect(transfer).to be_processing
    expect(transfer.transferred_at).to eq(result.telegram_message.sent_at)
    expect(DownloadTelegramAttachmentJob).to have_been_enqueued.with(result.telegram_message.id)
  end

  it "matches the remitter by username, case-insensitively" do
    create(:remitter, telegram_username: "laplap")
    update["message"]["from"]["id"] = 1
    update["message"]["from"]["username"] = "LapLap"

    expect(described_class.call(update).status).to eq(:queued_remitter_transfer)
  end

  it "routes a caption with a transfer code from an unknown sender, remitter to be picked" do
    update["message"]["caption"] = "chuyen khoan TK01"

    expect(described_class.call(update).status).to eq(:queued_remitter_transfer)
    expect(RemitterTransfer.sole.remitter).to be_nil
  end

  it "keeps an unknown sender's settlement whose caption only looks like a code (Bích 01 -> CH01)" do
    update["message"]["caption"] = "Bích 01"

    expect(described_class.call(update).status).to eq(:queued)
    expect(RemitterTransfer.count).to eq(0)
  end

  it "recognises a zero-padding variant from an unknown sender without relaxing word boundaries" do
    update["message"]["caption"] = "chuyen khoan TK1"
    expect(described_class.call(update).status).to eq(:queued_remitter_transfer)
    expect(RemitterTransfer.sole.remitter).to be_nil
  end

  it "routes the caption-less photos of a transfer album" do
    update["message"].merge!("media_group_id" => "album-2", "caption" => "TK01")
    described_class.call(update)
    second = { "update_id" => 900_010,
               "message" => update["message"].merge("message_id" => 78).except("caption") }

    expect(described_class.call(second).status).to eq(:queued_remitter_transfer)
    expect(RemitterTransfer.count).to eq(2)
  end

  it "treats other senders and inactive remitters as settlement bills" do
    create(:remitter, telegram_user_id: 4242, active: false)

    expect(described_class.call(update).status).to eq(:queued)
    expect(RemitterTransfer.count).to eq(0)
  end

  it "sends remitter photos down the normal path while the feature flag is off" do
    allow(AppConfig).to receive(:remitter_features_enabled?).and_return(false)
    create(:remitter, telegram_user_id: 4242)

    expect(described_class.call(update).status).to eq(:queued)
    expect(RemitterTransfer.count).to eq(0)
  end

  it "does not collect a remitter album" do
    create(:remitter, telegram_user_id: 4242)
    update["message"]["media_group_id"] = "album-1"

    described_class.call(update)
    expect(BillAlbum.count).to eq(0)
  end

  it "re-reads the code when the caption is edited before the sheet write" do
    create(:remitter, telegram_user_id: 4242)
    message = described_class.call(update).telegram_message
    transfer = message.remitter_transfer
    transfer.update!(status: "needs_review", review_reasons: [ "code_missing" ])
    allow(RemitterTransfers::Builder).to receive(:call)

    edit = { "update_id" => 900_002, "edited_message" => update["message"].merge("caption" => "TK01") }
    described_class.call(edit)

    expect(RemitterTransfers::Builder).to have_received(:call).with(remitter_transfer: transfer)
  end

  it "only flags a caption edit after the sheet write" do
    create(:remitter, telegram_user_id: 4242)
    transfer = described_class.call(update).telegram_message.remitter_transfer
    transfer.update!(status: "approved", written_at: Time.current)

    described_class.call({ "update_id" => 900_002, "edited_message" => update["message"].merge("caption" => "TK02") })

    expect(transfer.reload.metadata["caption_edited_after_write"]).to be(true)
  end
end

RSpec.describe AnalyzeBillImageJob, "remitter transfers" do
  def transfer_photo(message = create(:telegram_message, telegram_sender_id: 31))
    create(:bill_image, :analyzed, extraction: "transfer", telegram_message: message)
  end

  before { allow(AppConfig).to receive(:remitter_features_enabled?).and_return(true) }

  it "turns a single transfer photo into a transfer after OCR, even from an unknown sender" do
    bill_image = transfer_photo

    described_class.new.build_or_finalize(bill_image)

    transfer = RemitterTransfer.sole
    expect(transfer.bill_image).to eq(bill_image)
    expect(transfer.remitter).to be_nil
    expect(BuildRemitterTransferJob).to have_been_enqueued.with(transfer.id)
    expect(BuildTransactionJob).not_to have_been_enqueued
  end

  it "hands a code-only transfer back to the transaction path when OCR shows a settlement" do
    message = create(:telegram_message, telegram_sender_id: 31)
    transfer = create(:remitter_transfer, telegram_message: message, remitter: nil)
    bill_image = create(:bill_image, :analyzed, extraction: "normal_settlement", telegram_message: message)

    described_class.new.build_or_finalize(bill_image)

    expect(transfer.reload).to be_rejected
    expect(transfer.review_reasons).to eq([ "settlement_photo" ])
    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
    expect(BuildRemitterTransferJob).not_to have_been_enqueued
  end

  it "hands a registered remitter's settlement bill to the transaction path" do
    transfer = create(:remitter_transfer)
    bill_image = create(:bill_image, :analyzed, extraction: "normal_settlement",
                                    telegram_message: transfer.telegram_message)

    described_class.new.build_or_finalize(bill_image)

    expect(transfer.reload).to be_rejected
    expect(transfer.review_reasons).to eq([ "settlement_photo" ])
    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
    expect(BuildRemitterTransferJob).not_to have_been_enqueued
  end

  it "keeps a remitter's photo on the transfer path when OCR cannot tell what it is" do
    transfer = create(:remitter_transfer)
    unknown = BillVision::Normalizer.call({ "documents" => [] }, provider: "openai", model: "gpt-test")
    bill_image = create(:bill_image, telegram_message: transfer.telegram_message,
                                     normalized_extraction: unknown, ocr_status: "needs_review")

    described_class.new.build_or_finalize(bill_image)

    expect(transfer.reload).to be_processing
    expect(BuildRemitterTransferJob).to have_been_enqueued.with(transfer.id)
    expect(BuildTransactionJob).not_to have_been_enqueued
  end

  it "rebuilds the transaction, not the transfer, when a handed-back settlement is OCR'd again" do
    transfer = create(:remitter_transfer, status: "rejected", review_reasons: [ "settlement_photo" ])
    bill_image = create(:bill_image, :analyzed, extraction: "normal_settlement",
                                    telegram_message: transfer.telegram_message)

    described_class.new.build_or_finalize(bill_image)

    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
    expect(BuildRemitterTransferJob).not_to have_been_enqueued
  end

  it "hands a transfer back when an OCR retry succeeds and reads a settlement" do
    transfer = create(:remitter_transfer, status: "failed", review_reasons: [ "ocr_failed" ])
    bill_image = create(:bill_image, :analyzed, extraction: "normal_settlement",
                                    telegram_message: transfer.telegram_message)

    described_class.new.build_or_finalize(bill_image)

    expect(transfer.reload).to be_rejected
    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
  end

  it "keeps a transfer a person rejected on the transfer path" do
    transfer = create(:remitter_transfer, status: "rejected", review_reasons: [ "code_missing" ])
    bill_image = create(:bill_image, :analyzed, extraction: "normal_settlement",
                                    telegram_message: transfer.telegram_message)

    described_class.new.build_or_finalize(bill_image)

    expect(BuildTransactionJob).not_to have_been_enqueued
  end

  it "does not reclassify a transfer that was already evaluated" do
    transfer = create(:remitter_transfer, status: "approved")
    bill_image = create(:bill_image, :analyzed, extraction: "normal_settlement",
                                    telegram_message: transfer.telegram_message)

    described_class.new.build_or_finalize(bill_image)

    expect(transfer.reload).to be_approved
    expect(BuildTransactionJob).not_to have_been_enqueued
  end

  it "keeps a settlement photo on the transaction path" do
    bill_image = create(:bill_image, :analyzed, extraction: "normal_settlement")

    described_class.new.build_or_finalize(bill_image)

    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
    expect(RemitterTransfer.count).to eq(0)
  end

  it "keeps a duplicate of a photo that already has a transaction on the transaction path" do
    original = transfer_photo
    create(:transaction, bill_image: original, telegram_message: original.telegram_message)
    duplicate = create(:bill_image, telegram_message: create(:telegram_message), duplicate_of: original,
                                    ocr_status: "duplicate")

    expect(RemitterTransfers::Classifier.transfer_image?(duplicate)).to be(false)
  end

  it "keeps an agent album's transfer total on the album path" do
    bill_image = transfer_photo
    bill_image.update!(bill_album: create(:bill_album, telegram_chat: bill_image.telegram_chat))

    described_class.new.build_or_finalize(bill_image)

    expect(FinalizeBillAlbumJob).to have_been_enqueued.with(bill_image.bill_album_id)
    expect(RemitterTransfer.count).to eq(0)
  end

  it "creates neither a transfer nor a transaction while the feature is off" do
    allow(AppConfig).to receive(:remitter_features_enabled?).and_return(false)
    bill_image = transfer_photo

    described_class.new.build_or_finalize(bill_image)

    expect(BuildTransactionJob).not_to have_been_enqueued
    expect(RemitterTransfer.count).to eq(0)
    expect(bill_image.telegram_message.reload).to be_processing_ignored
  end

  it "builds the transfer instead of a transaction after OCR" do
    transfer = create(:remitter_transfer)
    bill_image = create(:bill_image, telegram_message: transfer.telegram_message)

    described_class.new.build_or_finalize(bill_image)

    expect(BuildRemitterTransferJob).to have_been_enqueued.with(transfer.id)
    expect(BuildTransactionJob).not_to have_been_enqueued
  end
end
