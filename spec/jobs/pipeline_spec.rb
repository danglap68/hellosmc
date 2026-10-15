require "rails_helper"

# End-to-end: Telegram update -> stored message -> image -> OCR -> transaction.
RSpec.describe "Telegram to transaction pipeline" do
  include_context "accounting setup"

  let(:update) { telegram_fixture("photo_update") }
  let(:client) { instance_double(Telegram::BotClient) }

  before do
    chat.update!(telegram_chat_id: -1001234567890)
    allow(Telegram::BotClient).to receive(:new).and_return(client)
    allow(client).to receive(:get_file).with("large-file").and_return({ "file_path" => "photos/large.jpg" })
    allow(client).to receive(:download_file).and_return(File.binread(bill_fixture_path("mb_settlement.jpg")))
    stub_vision(extraction_fixture("mb_settlement"))
  end

  it "turns an 'MB' photo into an approved MB transaction" do
    perform_enqueued_jobs do
      Telegram::UpdateReceiver.call(update)
    end

    transaction = Transaction.sole
    expect(transaction).to have_attributes(
      status: "approved", dealer: dealer, merchant: merchant, card_type: mb_card,
      transaction_amount_vnd: 10_000_000, applied_base_fee_rate: BigDecimal("0.011"),
      amount_after_base_fee_vnd: 9_890_000
    )
    expect(transaction.telegram_message.message_text).to eq("MB")
    expect(transaction.bill_image.image).to be_attached
    expect(transaction.bill_image.telegram_file_unique_id).to eq("large-uniq")
  end

  it "processes the same webhook delivery only once" do
    perform_enqueued_jobs do
      2.times { ProcessTelegramUpdateJob.perform_later(update) }
    end
    expect(Transaction.count).to eq(1)
    expect(BillImage.count).to eq(1)
  end
  it "keeps a known remitter's non-bill photo as an ignored message without accounting records" do
    allow(AppConfig).to receive(:remitter_features_enabled?).and_return(true)
    create(:remitter, telegram_user_id: update.dig("message", "from", "id"))
    stub_vision({ "documents" => [], "notes" => "Calculator screen, not a receipt" })

    perform_enqueued_jobs { Telegram::UpdateReceiver.call(update) }

    expect(RemitterTransfer.count).to eq(0)
    expect(Transaction.count).to eq(0)
    expect(TelegramMessage.sole).to be_processing_ignored
    expect(BillImage.sole.image).to be_attached
  end

  it "creates transfers only after OCR and routes duplicate receipts without another paid read" do
    allow(AppConfig).to receive(:remitter_features_enabled?).and_return(true)
    remitter = create(:remitter, telegram_user_id: update.dig("message", "from", "id"))
    stub_vision(extraction_fixture("transfer"))

    message = Telegram::UpdateReceiver.call(update).telegram_message
    expect(RemitterTransfer.count).to eq(0)
    perform_enqueued_jobs { DownloadTelegramAttachmentJob.perform_now(message.id) }
    expect(RemitterTransfer.sole).to have_attributes(remitter: remitter, status: "needs_review")

    second = update.deep_dup
    second["update_id"] += 1
    second["message"]["message_id"] += 1
    perform_enqueued_jobs { Telegram::UpdateReceiver.call(second) }

    expect(RemitterTransfer.count).to eq(2)
    expect(RemitterTransfer.last).to be_needs_review
    expect(RemitterTransfer.last.review_reasons).to include("possible_duplicate")
    expect(Transaction.count).to eq(0)
    expect(BillVision::Extractor).to have_received(:call).once
  end
end
