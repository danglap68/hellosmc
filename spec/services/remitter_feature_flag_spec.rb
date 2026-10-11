require "rails_helper"

# While remitter_features_enabled is off only settlement bills are processed.
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
    it "still builds the total (settlement or transfer) of an album for review" do
      %w[normal_settlement transfer].each do |extraction|
        bill_image = analyzed_bill(extraction: extraction)
        bill_image.update!(bill_album: create(:bill_album, telegram_chat: chat))

        transaction = Transactions::Builder.call(bill_image: bill_image).sole
        expect(transaction.review_reason_codes).to include("album_total_review")
      end
    end
  end

  describe Telegram::UpdateReceiver do
    let(:update) { telegram_fixture("photo_update") }
    let!(:chat) { create(:telegram_chat, telegram_chat_id: -1001234567890, active: true) }

    it "ignores images sent by a remitter without downloading them" do
      create(:remitter, telegram_user_id: 4242)

      result = described_class.call(update)

      expect(result.status).to eq(:ignored_remitter)
      expect(result.telegram_message).to be_processing_ignored
      expect(DownloadTelegramAttachmentJob).not_to have_been_enqueued
    end

    it "still queues images from other senders" do
      expect(described_class.call(update).status).to eq(:queued)
    end

    it "processes remitter images again when the flag is on" do
      allow(AppConfig).to receive(:remitter_features_enabled?).and_return(true)
      create(:remitter, telegram_user_id: 4242)

      expect(described_class.call(update).status).to eq(:queued)
    end
  end
end
