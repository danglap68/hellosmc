require "rails_helper"

# remitter_features_enabled off: no transfer flow; remitter photos take the
# normal path, so their settlement bills still become transactions. (Single
# photos only become transactions when they are settlements, flag on or off:
# see single_photo_settlement_only_spec.rb.)
RSpec.describe "remitter feature flag off" do
  include_context "accounting setup"

  before { allow(AppConfig).to receive(:remitter_features_enabled?).and_return(false) }

  it "defaults to off" do
    allow(AppConfig).to receive(:remitter_features_enabled?).and_call_original
    expect(AppSetting.get("remitter_features_enabled")).to be(false)
  end

  describe Transactions::Builder do
    it "still builds a settlement" do
      expect(described_class.call(bill_image: analyzed_bill)).to be_one
    end

    it "skips a transfer instead of creating a transaction" do
      expect(described_class.call(bill_image: analyzed_bill(extraction: "transfer"))).to be_empty
    end

    it "skips an unknown document instead of creating a review transaction" do
      normalized = BillVision::Normalizer.call({ "documents" => [] }, provider: "openai", model: "gpt-test")
      bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                       normalized_extraction: normalized, ocr_status: "needs_review")

      expect(described_class.call(bill_image: bill_image)).to be_empty
    end
  end

  describe "albums" do
    it "still builds the total of an album; a transfer total is always reviewed" do
      bill_image = analyzed_bill(extraction: "transfer")
      bill_image.update!(bill_album: create(:bill_album, telegram_chat: chat))

      transaction = Transactions::Builder.call(bill_image: bill_image).sole
      expect(transaction.review_reason_codes).to include("album_total_review")
    end

    it "builds a complete settlement of an album like a single photo" do
      bill_image = analyzed_bill(extraction: "normal_settlement")
      bill_image.update!(bill_album: create(:bill_album, telegram_chat: chat))

      transaction = Transactions::Builder.call(bill_image: bill_image).sole
      expect(transaction.review_reason_codes).not_to include("album_total_review")
    end
  end

  describe Telegram::UpdateReceiver do
    let(:update) { telegram_fixture("photo_update") }
    let!(:chat) { create(:telegram_chat, telegram_chat_id: -1001234567890, active: true) }

    it "queues a remitter's photo on the normal path so OCR can find a settlement bill" do
      create(:remitter, telegram_user_id: 4242)

      result = described_class.call(update)

      expect(result.status).to eq(:queued)
      expect(DownloadTelegramAttachmentJob).to have_been_enqueued.with(result.telegram_message.id)
      expect(RemitterTransfer.count).to eq(0)
    end

    it "does not collect a remitter's photos into an album: each is judged on its own after OCR" do
      create(:remitter, telegram_user_id: 4242)
      update["message"]["media_group_id"] = "album-remitter"
      second = { "update_id" => 900_010,
                 "message" => update["message"].merge("message_id" => 78).except("caption") }

      expect(described_class.call(update).status).to eq(:queued)
      expect(described_class.call(second).status).to eq(:queued)
      expect(BillAlbum.count).to eq(0)
      expect(DownloadTelegramAttachmentJob).to have_been_enqueued.twice
    end

    it "still collects an agent's album" do
      update["message"]["media_group_id"] = "album-agent"

      described_class.call(update)

      expect(BillAlbum.count).to eq(1)
    end

    it "queues a caption with a transfer code on the normal path" do
      update["message"]["caption"] = "TK01"

      expect(described_class.call(update).status).to eq(:queued)
      expect(RemitterTransfer.count).to eq(0)
    end

    it "still queues images from other senders" do
      expect(described_class.call(update).status).to eq(:queued)
    end

    it "turns remitter images into transfers when the flag is on" do
      allow(AppConfig).to receive(:remitter_features_enabled?).and_return(true)
      create(:remitter, telegram_user_id: 4242)

      expect(described_class.call(update).status).to eq(:queued_remitter_transfer)
      expect(RemitterTransfer.count).to eq(1)
    end
  end
end
