require "rails_helper"

RSpec.describe FeeRules::Seed do
  before do
    %w[mb napas].each { |key| CardType.find_or_create_by!(key: key) { |c| c.name = key.upcase } }
    Workbook::Seed.call
  end

  it "creates the five rules" do
    expect { described_class.call }.to change(FeeRule, :count).by(5)
  end

  it "is idempotent and keeps rates edited in the admin" do
    described_class.call
    rule = FeeRule.find_by!("metadata ->> 'seed_key' = 'system_default'")
    rule.update!(base_fee_rate: BigDecimal("0.02"))

    expect { described_class.call }.not_to change(FeeRule, :count)
    expect(rule.reload.base_fee_rate).to eq(BigDecimal("0.02"))
  end

  it "targets the right merchants and card types" do
    described_class.call
    nct = FeeRule.find_by!("metadata ->> 'seed_key' = 'hkd_as_cafe_nct'")
    expect(nct.merchants.map(&:name)).to contain_exactly("HKD AS CAFE", "HKD NCT", "HKD NCT MBV")
    expect(nct.base_fee_rate).to eq(BigDecimal("0.0115"))
    expect(nct.dealer_rate).to eq(BigDecimal("0.014"))

    cards = FeeRule.find_by!("metadata ->> 'seed_key' = 'card_mb_napas'")
    expect(cards.card_types.map(&:key)).to contain_exactly("mb", "napas")
    expect(FeeRule.find_by!("metadata ->> 'seed_key' = 'system_default'")).to be_system_default
  end
end
