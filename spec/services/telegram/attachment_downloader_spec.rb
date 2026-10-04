require "rails_helper"

RSpec.describe Telegram::AttachmentDownloader do
  let(:message) { create(:telegram_message) }
  let(:image_bytes) { File.binread(bill_fixture_path("normal_settlement.jpg")) }
  let(:client) { instance_double(Telegram::BotClient) }

  before do
    allow(client).to receive(:get_file).and_return({ "file_path" => "photos/file_1.jpg" })
    allow(client).to receive(:download_file).and_return(image_bytes)
  end

  it "downloads, fingerprints and stores the image" do
    bill_image = described_class.call(message, client: client)

    expect(bill_image).to be_persisted
    expect(bill_image.image).to be_attached
    expect(bill_image.sha256).to eq(Digest::SHA256.hexdigest(image_bytes))
    expect(bill_image.mime_type).to eq("image/jpeg")
    expect([ bill_image.width, bill_image.height ]).to eq([ 420, 640 ])
    expect(bill_image.telegram_file_unique_id).to eq("uniq-#{message.telegram_message_id}")
    expect(bill_image.image.blob.key).to start_with("bills/")
    expect(bill_image).to be_ocr_pending
  end

  it "returns the existing image when run twice for the same message" do
    first = described_class.call(message, client: client)
    expect(described_class.call(message, client: client)).to eq(first)
    expect(client).to have_received(:download_file).once
  end

  it "records identical bytes from another message as a duplicate without storing it again" do
    original = described_class.call(message, client: client)
    other = create(:telegram_message, telegram_chat: message.telegram_chat)

    duplicate = described_class.call(other, client: client)
    expect(duplicate).to be_ocr_duplicate
    expect(duplicate.duplicate_of).to eq(original)
    expect(duplicate.image).not_to be_attached
  end

  it "records a re-sent Telegram file as a duplicate without downloading" do
    original = described_class.call(message, client: client)
    other = create(:telegram_message, telegram_chat: message.telegram_chat)
    other.raw_payload["message"]["photo"].first["file_unique_id"] = original.telegram_file_unique_id
    other.save!

    duplicate = described_class.call(other, client: client)
    expect(duplicate).to be_ocr_duplicate
    expect(client).to have_received(:download_file).once
  end

  it "rejects non-image content" do
    allow(client).to receive(:download_file).and_return("%PDF-1.4 not an image")
    expect { described_class.call(message, client: client) }.to raise_error(described_class::InvalidImageError)
    expect(BillImage.count).to eq(0)
  end
end
