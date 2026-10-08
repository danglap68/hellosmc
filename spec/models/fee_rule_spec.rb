require "rails_helper"

RSpec.describe FeeRule do
  it "converts UI percentages to exact decimal rates" do
    rule = build(:fee_rule, base_fee_percent: "0,88", dealer_percent: "1.21")
    expect(rule.base_fee_rate).to eq(BigDecimal("0.0088"))
    expect(rule.dealer_rate).to eq(BigDecimal("0.0121"))
    expect(rule.base_fee_percent).to eq("0,88")
  end

  it "renders stored rates as percentages" do
    rule = FeeRule.new(base_fee_rate: BigDecimal("0.0125"))
    expect(rule.base_fee_percent).to eq("1.25")
  end

  it "rejects unparseable percentages" do
    rule = build(:fee_rule, base_fee_percent: "abc")
    expect(rule).not_to be_valid
    expect(rule.errors[:base_fee_rate]).to be_present
  end

  it "rejects rates outside [0, 1)" do
    expect(build(:fee_rule, base_fee_rate: 1)).not_to be_valid
    expect(build(:fee_rule, base_fee_rate: -0.01)).not_to be_valid
  end

  it "may be a system default with no targeting" do
    expect(build(:fee_rule)).to be_valid
    expect(build(:fee_rule).specificity_level).to eq("system_default")
  end

  it "requires effective_until after effective_from" do
    rule = build(:fee_rule, effective_from: Time.zone.local(2026, 5, 1), effective_until: Time.zone.local(2026, 4, 1))
    expect(rule).not_to be_valid
  end

  it "refuses a merchant that belongs to another dealer" do
    merchant = create(:merchant)
    rule = build(:fee_rule, merchant: merchant, dealer: create(:dealer))
    expect(rule).not_to be_valid
    expect(rule.errors[:merchant_ids]).to be_present
  end

  describe "overlap protection" do
    let(:merchant) { create(:merchant) }

    before { create(:fee_rule, merchant: merchant, effective_from: Time.zone.local(2026, 1, 1)) }

    it "refuses an overlapping rule with the same targeting and priority" do
      rule = build(:fee_rule, merchant: merchant, effective_from: Time.zone.local(2026, 6, 1))
      expect(rule).not_to be_valid
      expect(rule.errors[:base]).to be_present
    end

    it "accepts the same targeting with a different priority" do
      expect(build(:fee_rule, merchant: merchant, priority: 50)).to be_valid
    end

    it "accepts a non-overlapping window once the old rule is closed" do
      FeeRule.first.update!(effective_until: Time.zone.local(2026, 6, 1))
      expect(build(:fee_rule, merchant: merchant, effective_from: Time.zone.local(2026, 6, 1))).to be_valid
    end
  end

  describe "several households on one rule" do
    it "refuses another rule that shares one household" do
      first, second = create_list(:merchant, 2)
      create(:fee_rule, merchants: [ first, second ])
      expect(build(:fee_rule, merchant: second)).not_to be_valid
    end

    it "accepts a rule whose households do not overlap" do
      create(:fee_rule, merchant: create(:merchant))
      expect(build(:fee_rule, merchant: create(:merchant))).to be_valid
    end
  end

  describe "several card types on one rule" do
    it "applies to each selected card and refuses a rule that shares one card" do
      mb = create(:mb_card_type)
      napas = create(:napas_card_type)
      create(:fee_rule, card_types: [ mb, napas ])
      expect(build(:fee_rule, card_type: napas)).not_to be_valid
      expect(build(:fee_rule, card_type: create(:normal_card_type))).to be_valid
    end
  end

  describe "#specificity_level" do
    let(:merchant) { create(:merchant) }
    let(:card_type) { create(:mb_card_type) }

    it "orders levels from most to least specific" do
      expect(build(:fee_rule, merchant: merchant, card_type: card_type).specificity_level).to eq("merchant_card_type")
      expect(build(:fee_rule, dealer: merchant.dealer, card_type: card_type).specificity_level).to eq("dealer_card_type")
      expect(build(:fee_rule, merchant: merchant).specificity_level).to eq("merchant")
      expect(build(:fee_rule, dealer: merchant.dealer).specificity_level).to eq("dealer")
      expect(build(:fee_rule, card_type: card_type).specificity_level).to eq("card_type")
    end
  end
end
