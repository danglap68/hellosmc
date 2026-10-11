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

  it "resolves HKD + agent (tid1) + remitter from the OCR name suffix" do
    lap = create(:remitter, name: "Lập", excel_key: "LẬP", telegram_user_id: 12_345)
    result = described_class.call(transaction: build_transaction(merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1"))
    expect(result).to be_identified
    expect(result.merchant).to eq(hkd)
    expect(result.merchant_dealer).to eq(link)
    expect(result.remitter).to eq(lap)
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

  it "returns agent_tid_unmapped when the tid_key has no merchant_dealer" do
    result = described_class.call(transaction: build_transaction(merchant_name: "HỘ KINH DOANH THIÊN KIM GV-9"))
    expect(result).to be_unidentified
    expect(result.issue).to eq("agent_tid_unmapped")
  end

  it "falls back to the chat merchant when the transaction merchant is absent" do
    chat = create(:telegram_chat, merchants: [ hkd ])
    message = create(:telegram_message, telegram_chat: chat, telegram_sender_id: 12_345)
    bill_image = create(:bill_image, telegram_message: message)
    transaction = create(:transaction, merchant: nil, telegram_message: message, bill_image: bill_image,
                         source_data: { "extraction" => { "merchant_name" => "HỘ KINH DOANH THIÊN KIM GV-1" } })
    result = described_class.call(transaction: transaction)
    expect(result).to be_identified
    expect(result.merchant).to eq(hkd)
  end

  it "returns merchant_missing when there is no merchant and no chat merchant" do
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

  describe "Telegram group title" do
    let(:lan) { create(:dealer, name: "Chị Lan") }

    def transaction_in(chat, merchant_name:, merchant: hkd)
      message = create(:telegram_message, telegram_chat: chat, telegram_sender_id: 12_345)
      bill_image = create(:bill_image, telegram_message: message)
      create(:transaction, merchant: merchant, telegram_message: message, bill_image: bill_image,
             source_data: { "extraction" => { "merchant_name" => merchant_name } })
    end

    before { create(:merchant_dealer, merchant: hkd, dealer: lan, tid_key: "tid2", ds_sheet_anchor: "Thiên Kim GV", ds_header: "Lan (tid2)", rd_agent_label: "Lan") }

    it "writes to the agent's row when title and TID agree" do
      chat = create(:telegram_chat, name: "Chị Lan-Thiên Kim GV")
      result = described_class.call(transaction: transaction_in(chat, merchant_name: "HỘ KINH DOANH THIÊN KIM GV-2"))
      expect(result).to be_identified
      expect(result.merchant_dealer.dealer).to eq(lan)
    end

    it "goes unidentified when the TID belongs to a different agent than the title" do
      chat = create(:telegram_chat, name: "Chị Lan-Thiên Kim GV")
      result = described_class.call(transaction: transaction_in(chat, merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1"))
      expect(result).to be_unidentified
      expect(result.issue).to eq("agent_group_mismatch")
    end

    it "does not guess the merchant when the group serves several HKDs" do
      other = create(:merchant)
      chat = create(:telegram_chat, merchants: [ hkd, other ])
      result = described_class.call(transaction: transaction_in(chat, merchant_name: "HỘ KINH DOANH THIÊN KIM GV-1", merchant: nil))
      expect(result).to be_unidentified
      expect(result.issue).to eq("merchant_missing")
    end
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
