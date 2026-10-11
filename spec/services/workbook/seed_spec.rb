require "rails_helper"

RSpec.describe Workbook::Seed do
  it "creates the 5 remitters idempotently" do
    expect { described_class.call }.to change(Remitter, :count).by(5)
    expect { described_class.call }.not_to change(Remitter, :count)
    expect(Remitter.find_by!(excel_key: "LẬP").name).to eq("Lập")
  end

  it "maps Thiên Kim GV tid1 → Chương" do
    described_class.call
    link = Merchant.find_by!(code: "001").merchant_dealers.find_by!(tid_key: "tid1")
    expect(link.dealer.name).to eq("Chương")
    expect(link.ds_header).to eq("Chương (tid1)")
  end

  it "maps Hải's R&D label to NamHai" do
    described_class.call
    link = Merchant.find_by!(code: "001").merchant_dealers.find_by!(tid_key: "tid3")
    expect(link.rd_agent_label).to eq("NamHai")
  end

  it "gives Chị Huệ three TIDs under the same HKD without merging" do
    described_class.call
    links = Merchant.find_by!(code: "MILO001").merchant_dealers.order(:tid_key)
    expect(links.map(&:tid_key)).to eq(%w[tid127 tid128 tid129])
  end

  it "reuses the same dealer across two HKDs" do
    described_class.call
    expect(Dealer.find_by!(name: "Cường Duyên").merchant_dealers.count).to eq(2)
  end

  it "seeds the two NCT HKDs with their agents" do
    described_class.call
    nct = Merchant.find_by!(code: "NCT001")
    expect(nct.merchant_dealers.map { |md| [ md.tid_key, md.dealer.name ] }).to contain_exactly(
      %w[tid1 Chị\ Mến], %w[tid2 Anh\ Hải], %w[tid3 Nghiệp]
    )
    nct_mbv = Merchant.find_by!(code: "NCTMBV001")
    expect(nct_mbv.merchant_dealers.map { |md| [ md.tid_key, md.dealer.name ] }).to contain_exactly(
      %w[tid1 Sơn], %w[tid2 Anh\ Thọ], %w[tid3 Tuân]
    )
  end

  it "does not duplicate an existing merchant matched by code" do
    create(:merchant, code: "001", name: "001_ HỘ KINH DOANH THIÊN KIM GV")
    described_class.call
    expect(Merchant.where(code: "001").count).to eq(1)
  end

  it "matches existing merchants by match_code instead of creating duplicates" do
    cherry = create(:merchant, code: "002 CHERRY COFFE", name: "CHERRY COFFE")
    described_class.call
    expect(Merchant.where(code: "CHERRY001")).not_to exist
    expect(cherry.merchant_dealers).to be_present
  end

  it "is idempotent for merchant_dealers" do
    described_class.call
    expect { described_class.call }.not_to change(MerchantDealer, :count)
  end

  it "uses bare agent names for the remitter-report labels" do
    described_class.call
    labels = MerchantDealer.pluck(:rd_agent_label).compact
    expect(labels).to include("Mến", "Thọ")
    expect(labels).not_to include("Chị Mến", "Anh Thọ")
  end

  it "overwrites mapping fields on re-run" do
    described_class.call
    link = Merchant.find_by!(code: "001").merchant_dealers.find_by!(tid_key: "tid3")
    link.update!(rd_agent_label: "Sai")
    described_class.call
    expect(link.reload.rd_agent_label).to eq("NamHai")
  end

  describe ".seed_telegram_chats" do
    it "creates one chat per dealer with its HKDs, idempotently" do
      described_class.call
      expect { described_class.seed_telegram_chats }.to change(TelegramChat, :count).by(Dealer.count)
      expect { described_class.seed_telegram_chats }.not_to change(TelegramChat, :count)
      chat = TelegramChat.find_by!("name LIKE ?", "Cường Duyên-%")
      expect(chat.merchants.count).to eq(2)
      expect(chat.group_dealer.name).to eq("Cường Duyên")
    end
  end
end
