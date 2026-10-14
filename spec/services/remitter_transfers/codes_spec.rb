require "rails_helper"

RSpec.describe RemitterTransfers::Codes do
  it "seeds the 23 starting codes, each on exactly one agent row" do
    Workbook::Seed.call

    expect(described_class.codes.size).to eq(23)
    expect(described_class.codes).to all(match(described_class::FORMAT))
    expect(described_class.codes.uniq.size).to eq(23)
    described_class.codes.each do |code|
      expect(described_class.merchant_dealer_for(code)).to be_present, "#{code} has no active merchant_dealers row"
    end
  end

  it "maps TK01 to Thiên Kim GV, tid1, Chương" do
    Workbook::Seed.call

    link = described_class.merchant_dealer_for("tk01")
    expect(link.merchant.code).to eq("001")
    expect(link.tid_key).to eq("tid1")
    expect(link.dealer.name).to eq("Chương")
  end

  it "follows a code the client set on an agent row" do
    Workbook::Seed.call
    link = Merchant.find_by!(code: "001").merchant_dealers.find_by!(tid_key: "tid1")
    link.update!(transfer_code: "tk 77")

    expect(described_class.merchant_dealer_for("TK77")).to eq(link)
    expect(described_class.merchant_dealer_for("TK01")).to be_nil
    expect(described_class.codes).to include("TK77")
    expect(described_class.codes).not_to include("TK01")
  end

  it "returns nil for an unknown code or an inactive agent row, but still recognises the inactive one's code" do
    Workbook::Seed.call
    expect(described_class.merchant_dealer_for("ZZ99")).to be_nil
    expect(described_class.merchant_dealer_for(nil)).to be_nil

    described_class.merchant_dealer_for("TK01").update!(active: false)
    expect(described_class.merchant_dealer_for("TK01")).to be_nil
    expect(described_class.codes).to include("TK01")
  end

  it "lists every configured code with its HKD and agent for display" do
    Workbook::Seed.call

    link = described_class.all.fetch("NM03")
    expect(link.merchant.code).to eq("NCTMBV001")
    expect(link.dealer.name).to eq("Tuân")
  end

  it "resolves missing/extra zero padding to the configured agent but refuses colliding legacy codes" do
    link = create(:merchant_dealer, transfer_code: "TK01")
    expect(described_class.merchant_dealer_for("tk 001")).to eq(link)
    expect(described_class.merchant_dealer_for("TK1")).to eq(link)
    expect(described_class.merchant_dealer_for("TK10")).to be_nil
    # Simulate legacy data created before padding uniqueness was validated.
    other = create(:merchant_dealer, transfer_code: "ZZ1")
    other.update_column(:transfer_code, "TK1")
    expect(described_class.merchant_dealer_for("TK01")).to be_nil
  end
end
