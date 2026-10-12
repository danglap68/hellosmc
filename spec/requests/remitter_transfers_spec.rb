require "rails_helper"

RSpec.describe "Remitter transfers" do
  before { sign_in create(:user, :admin) }

  let(:message) { create(:telegram_message) }
  let(:transfer) do
    data = extraction_fixture("transfer")
    data["documents"][0].merge!("transaction_date" => "2026-10-12", "transaction_time" => "10:23:25")
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    image = create(:bill_image, telegram_message: message, normalized_extraction: normalized, ocr_status: "completed")
    create(:remitter_transfer, telegram_message: message, bill_image: image, status: "needs_review",
                               transferred_at: Time.zone.local(2026, 10, 12, 18, 0, 0))
  end

  it "shows the date and time on the bank slip next to when it was posted" do
    transfer
    get admin_remitter_transfers_path

    expect(response.body).to include("Ngày giờ chuyển khoản", "Gửi lúc", "12/10/2026 10:23:25", "12/10/2026 18:00:00")
  end

  it "shows it on the transfer page too" do
    get admin_remitter_transfer_path(transfer)

    expect(response.body).to include("Ngày giờ chuyển khoản", "12/10/2026 10:23:25")
  end

  it "shows only the date when OCR read no time" do
    data = extraction_fixture("transfer")
    data["documents"][0].merge!("transaction_date" => "2026-10-12", "transaction_time" => nil)
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    image = create(:bill_image, telegram_message: message, normalized_extraction: normalized, ocr_status: "completed")
    create(:remitter_transfer, telegram_message: message, bill_image: image, status: "needs_review",
                               transferred_at: Time.zone.local(2026, 10, 13, 9, 0, 0))

    get admin_remitter_transfers_path

    expect(response.body).to include("12/10/2026</td>")
    expect(response.body).not_to include("12/10/2026 ")
  end

  it "shows a dash when the slip has no date" do
    data = extraction_fixture("transfer")
    data["documents"][0].merge!("transaction_date" => nil, "transaction_time" => nil)
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    image = create(:bill_image, telegram_message: message, normalized_extraction: normalized, ocr_status: "completed")
    create(:remitter_transfer, telegram_message: message, bill_image: image, status: "needs_review")

    get admin_remitter_transfers_path

    expect(response).to have_http_status(:ok)
  end

  it "lists a skipped photo under the rejected tab with the reason" do
    message.update!(message_text: "TK01")
    create(:remitter_transfer, telegram_message: message, status: "rejected", review_reasons: [ "not_a_transfer" ])

    get admin_remitter_transfers_path(queue: "rejected")

    expect(response.body).to include("Ảnh không phải biên lai chuyển khoản")
  end
end
