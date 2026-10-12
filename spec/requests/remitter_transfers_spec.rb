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
  describe "where the message came from" do
    let(:chat) { create(:telegram_chat, name: "Nhóm Thiên Kim", telegram_chat_id: -1001234567890) }
    let(:message) do
      create(:telegram_message, telegram_chat: chat, telegram_message_id: 4242, sender_name: "Đặng Văn Lập", telegram_username: "laplap",
                                telegram_sender_id: 777_000, message_text: "Lap chuyen tien TK01", sent_at: Time.zone.local(2026, 10, 12, 16, 4, 24),
                                processing_status: "processed")
    end

    it "gives the group, who sent it, when, the message id and what they wrote on the transfer page" do
      get admin_remitter_transfer_path(transfer)

      expect(response.body).to include("Nguồn Telegram", "Nhóm Thiên Kim", "-1001234567890", "Đặng Văn Lập", "@laplap", "777000",
                                       "12/10/2026 16:04:24", "4242", "Lap chuyen tien TK01", "Đã xử lý")
    end

    it "says when the text comes from the first message of the album, and how many photos it has" do
      first = create(:telegram_message, telegram_chat: chat, media_group_id: "G1", message_text: "TK02 chuyen tien", telegram_message_id: 10)
      second = create(:telegram_message, telegram_chat: chat, media_group_id: "G1", message_text: nil, telegram_message_id: 11)
      data = extraction_fixture("transfer")
      image = create(:bill_image, telegram_message: second, ocr_status: "completed",
                                  normalized_extraction: BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test"))
      create(:remitter_transfer, telegram_message: first, status: "needs_review")
      later = create(:remitter_transfer, telegram_message: second, bill_image: image, status: "needs_review")

      get admin_remitter_transfer_path(later)

      expect(response.body).to include("2 ảnh gửi cùng lúc", "G1", "TK02 chuyen tien", "Lấy từ tin nhắn đầu của album")
    end

    it "shows the same block on the transaction page" do
      transaction = create(:transaction, telegram_message: message)

      get admin_transaction_path(transaction)

      expect(response.body).to include("Nguồn Telegram", "Nhóm Thiên Kim", "Đặng Văn Lập", "@laplap", "Lap chuyen tien TK01")
    end
  end
end
