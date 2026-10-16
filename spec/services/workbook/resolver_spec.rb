require "rails_helper"

RSpec.describe Workbook::Resolver do
  let(:hkd) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001") }
  let(:chuong) { create(:dealer, name: "Chương") }
  let!(:link) do
    create(:merchant_dealer, merchant: hkd, dealer: chuong, tid_key: "tid1",
           ds_sheet_anchor: "Thiên Kim GV", ds_header: "Chương (tid1)", rd_agent_label: "Chương")
  end

  def build_transaction(merchant_name:, merchant: hkd, sender_id: 12_345, username: nil, terminal: nil)
    message = create(:telegram_message, telegram_sender_id: sender_id, telegram_username: username)
    bill_image = create(:bill_image, telegram_message: message)
    create(:transaction, merchant: merchant, telegram_message: message, bill_image: bill_image,
           source_data: { "extraction" => { "merchant_name" => merchant_name,
                                            "terminal_or_merchant_id" => terminal } })
  end

  it "resolves HKD + agent (tid1) from the OCR name suffix, without any remitter" do
    create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
    result = described_class.call(transaction: build_transaction(merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1"))
    expect(result).to be_identified
    expect(result.merchant).to eq(hkd)
    expect(result.merchant_dealer).to eq(link)
    expect(result).not_to respond_to(:remitter)
  end

  it "returns agent_tid_missing when the OCR name has no TID" do
    result = described_class.call(transaction: build_transaction(merchant_name: "HỘ KINH DOANH THIÊN KIM GV"))
    expect(result).to be_unidentified
    expect(result.issue).to eq("agent_tid_missing")
  end

  it "ignores terminal_or_merchant_id when resolving the agent" do
    result = described_class.call(
      transaction: build_transaction(merchant_name: "HỘ KINH DOANH THIÊN KIM GV", terminal: "TID 127")
    )
    expect(result).to be_unidentified
    expect(result.issue).to eq("agent_tid_missing")
  end

  describe "a bill whose TID gives no agent row" do
    def approved_without_tid(dealer)
      create(:transaction, :approved, merchant: hkd, dealer: dealer,
                                      source_data: { "extraction" => { "merchant_name" => "001: HỘ KINH DOANH THIÊN KIM" } })
    end

    it "uses the only agent row of the dealer the reviewer approved" do
      result = described_class.call(transaction: approved_without_tid(chuong))

      expect(result).to be_identified
      expect(result.merchant_dealer).to eq(link)
    end

    it "stays unidentified when that dealer has several rows in the HKD" do
      create(:merchant_dealer, merchant: hkd, dealer: chuong, tid_key: "tid2", ds_sheet_anchor: "Thiên Kim GV", ds_header: "Chương (tid2)")

      expect(described_class.call(transaction: approved_without_tid(chuong)).issue).to eq("agent_tid_missing")
    end
  end

  it "returns agent_tid_unmapped when the tid_key has no merchant_dealer" do
    result = described_class.call(transaction: build_transaction(merchant_name: "HỘ KINH DOANH THIÊN KIM GV-9"))
    expect(result).to be_unidentified
    expect(result.issue).to eq("agent_tid_unmapped")
  end

  it "returns merchant_missing when the bill names no HKD" do
    transaction = build_transaction(merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1", merchant: nil)
    result = described_class.call(transaction: transaction)
    expect(result).to be_unidentified
    expect(result.issue).to eq("merchant_missing")
  end

  it "ignores inactive merchant_dealers" do
    link.update!(active: false)
    result = described_class.call(transaction: build_transaction(merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1"))
    expect(result).to be_unidentified
    expect(result.issue).to eq("agent_tid_unmapped")
  end

  it "ignores the Telegram group: its name never picks the agent or the HKD" do
    lan = create(:dealer, name: "Chị Lan")
    create(:merchant_dealer, merchant: hkd, dealer: lan, tid_key: "tid2", ds_sheet_anchor: "Thiên Kim GV",
                             ds_header: "Lan (tid2)", rd_agent_label: "Lan")
    chat = create(:telegram_chat, name: "Chị Lan-Thiên Kim GV")
    message = create(:telegram_message, telegram_chat: chat, telegram_sender_id: 12_345)
    transaction = create(:transaction, merchant: hkd, telegram_message: message,
                                       bill_image: create(:bill_image, telegram_message: message),
                                       source_data: { "extraction" => { "merchant_name" => "HỘ KINH DOANH THIÊN KIM GV-1" } })

    result = described_class.call(transaction: transaction)

    expect(result).to be_identified
    expect(result.merchant_dealer.tid_key).to eq("tid1")
  end

  describe "bank transfer recipient" do
    let(:son) { create(:dealer, name: "Sơn") }

    before do
      create(:merchant_dealer, merchant: hkd, dealer: son, tid_key: "tid2",
             ds_sheet_anchor: "Thiên Kim GV", ds_header: "Sơn (tid2)", rd_agent_label: "Sơn")
    end

    def transfer(recipient, merchant_name: nil)
      message = create(:telegram_message, telegram_sender_id: 12_345)
      bill_image = create(:bill_image, telegram_message: message)
      create(:transaction, merchant: hkd, telegram_message: message, bill_image: bill_image,
             source_data: { "extraction" => { "merchant_name" => merchant_name, "recipient_name" => recipient } })
    end

    it "identifies the agent from the receiving account holder" do
      result = described_class.call(transaction: transfer("TRAN NGUYEN KHANH SON"))
      expect(result).to be_identified
      expect(result.merchant_dealer.dealer).to eq(son)
    end

    it "goes unidentified when the recipient contradicts the TID" do
      result = described_class.call(transaction: transfer("TRAN NGUYEN KHANH SON", merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1"))
      expect(result).to be_unidentified
      expect(result.issue).to eq("agent_recipient_mismatch")
    end
  end
end
