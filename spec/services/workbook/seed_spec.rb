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

  it "does not duplicate an existing merchant matched by code" do
    create(:merchant, code: "001", name: "001_ HỘ KINH DOANH THIÊN KIM GV")
    described_class.call
    expect(Merchant.where(code: "001").count).to eq(1)
  end

  it "matches existing merchants by match_code instead of creating duplicates" do
    cherry = create(:merchant, code: "002 CHERRY COFFE 2", name: "CHERRY COFFE 2")
    described_class.call
    expect(Merchant.where(code: "CHERRY001")).not_to exist
    expect(cherry.merchant_dealers).to be_present
  end

  it "is idempotent for merchant_dealers" do
    described_class.call
    expect { described_class.call }.not_to change(MerchantDealer, :count)
  end
end
