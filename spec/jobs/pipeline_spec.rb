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
end
