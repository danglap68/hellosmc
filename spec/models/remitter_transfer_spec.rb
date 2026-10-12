require "rails_helper"

RSpec.describe RemitterTransfer do
  let(:message) { create(:telegram_message) }

  def transfer_with(date:, time:, document_type: "transfer")
    data = extraction_fixture("transfer")
    data["documents"][0].merge!("transaction_date" => date, "transaction_time" => time, "document_type" => document_type)
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    image = create(:bill_image, telegram_message: message, normalized_extraction: normalized, ocr_status: "completed")
    create(:remitter_transfer, telegram_message: message, bill_image: image, transferred_at: Time.zone.local(2026, 10, 4, 18, 0, 0))
  end

  describe "#slip_at" do
    it "is the date and time printed on the bank slip, not when the photo was posted" do
      expect(transfer_with(date: "2026-10-12", time: "10:23:25").slip_at).to eq(Time.zone.local(2026, 10, 12, 10, 23, 25))
    end

    it "is the date alone when OCR read no time" do
      expect(transfer_with(date: "2026-10-12", time: nil).slip_at).to eq(Date.new(2026, 10, 12))
    end

    it "is nil when the slip shows no date or the photo is not a transfer" do
      expect(transfer_with(date: nil, time: nil).slip_at).to be_nil
    end

    it "is nil for a date that cannot be read" do
      expect(transfer_with(date: "not-a-date", time: "10:00:00").slip_at).to be_nil
    end

    it "reads the original photo when the upload was a duplicate" do
      original = transfer_with(date: "2026-10-12", time: "10:23:25")
      duplicate_message = create(:telegram_message, telegram_chat: message.telegram_chat)
      copy = create(:bill_image, telegram_message: duplicate_message, duplicate_of: original.bill_image, ocr_status: "duplicate")
      transfer = create(:remitter_transfer, telegram_message: duplicate_message, bill_image: copy)

      expect(transfer.slip_at).to eq(Time.zone.local(2026, 10, 12, 10, 23, 25))
    end
  end
end
