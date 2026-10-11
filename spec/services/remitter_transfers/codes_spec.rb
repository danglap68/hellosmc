require "rails_helper"

RSpec.describe RemitterTransfers::Codes do
  it "loads a well-formed table without duplicate HKD + TID pairs" do
    expect(described_class.codes).to all(match(described_class::FORMAT))
    pairs = described_class.all.values.map { |entry| [ entry.hkd, entry.tid ] }
    expect(pairs.uniq.size).to eq(pairs.size)
  end

  it "points every code at exactly one active agent row once the HKDs are seeded" do
    Workbook::Seed.call

    described_class.codes.each do |code|
      expect(described_class.merchant_dealer_for(code)).to be_present, "#{code} has no merchant_dealers row"
    end
  end

  it "maps TK01 to Thiên Kim GV, tid1, Chương" do
    Workbook::Seed.call

    link = described_class.merchant_dealer_for("tk01")
    expect(link.merchant.code).to eq("001")
    expect(link.tid_key).to eq("tid1")
    expect(link.dealer.name).to eq("Chương")
  end

  it "finds an HKD stored under its older code (match_code)" do
    create(:merchant, name: "Cherry Coffee", code: "002 CHERRY COFFE")

    expect(described_class.merchant_for("CHERRY001").code).to eq("002 CHERRY COFFE")
  end

  it "returns nil for an unknown code or an inactive agent row" do
    Workbook::Seed.call
    expect(described_class.merchant_dealer_for("ZZ99")).to be_nil

    described_class.merchant_dealer_for("TK01").update!(active: false)
    expect(described_class.merchant_dealer_for("TK01")).to be_nil
  end

  it "lists the codes of an agent row without a query per table entry" do
    Workbook::Seed.call
    link = MerchantDealer.includes(:merchant).find(described_class.merchant_dealer_for("NM03").id)

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) }
    codes = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      described_class.for_merchant_dealer(link)
    end

    expect(codes).to eq([ "NM03" ])
    expect(queries).to eq(0)
  end
end
