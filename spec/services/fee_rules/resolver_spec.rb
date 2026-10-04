require "rails_helper"

RSpec.describe FeeRules::Resolver do
  let(:at) { Time.zone.local(2026, 10, 4, 10, 0) }
  let(:dealer) { create(:dealer) }
  let(:merchant) { create(:merchant, dealer: dealer) }
  let(:mb) { create(:mb_card_type) }
  let(:normal) { create(:normal_card_type) }

  def resolve(card_type: mb, merchant: self.merchant, dealer: self.dealer, time: at)
    described_class.call(merchant: merchant, dealer: dealer, card_type: card_type, at: time)
  end

  it "prefers merchant + card type over everything else" do
    create(:fee_rule, base_fee_rate: BigDecimal("0.0088"))
    create(:fee_rule, dealer: dealer, base_fee_rate: BigDecimal("0.0110"))
    create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0115"))
    create(:fee_rule, dealer: dealer, card_type: mb, base_fee_rate: BigDecimal("0.0117"))
    specific = create(:fee_rule, merchant: merchant, card_type: mb, base_fee_rate: BigDecimal("0.0121"))

    result = resolve
    expect(result).to be_resolved
    expect(result.fee_rule).to eq(specific)
    expect(result.level).to eq("merchant_card_type")
  end

  it "walks down the specificity ladder" do
    default = create(:fee_rule, base_fee_rate: BigDecimal("0.0088"))
    card_only = create(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0110"))
    dealer_rule = create(:fee_rule, dealer: dealer, base_fee_rate: BigDecimal("0.0115"))

    expect(resolve.fee_rule).to eq(dealer_rule)
    dealer_rule.update!(active: false)
    expect(resolve.fee_rule).to eq(card_only)
    expect(resolve(card_type: normal).fee_rule).to eq(default)
  end

  it "uses priority (lower wins) inside the same level" do
    create(:fee_rule, merchant: merchant, priority: 100, base_fee_rate: BigDecimal("0.0125"))
    preferred = create(:fee_rule, merchant: merchant, priority: 10, base_fee_rate: BigDecimal("0.0140"))
    expect(resolve.fee_rule).to eq(preferred)
  end

  it "reports ambiguity instead of choosing between equal rules" do
    create(:fee_rule, merchant: merchant, card_type: mb, priority: 100)
    other = build(:fee_rule, merchant: merchant, card_type: mb, priority: 100, base_fee_rate: BigDecimal("0.0121"))
    other.save!(validate: false) # bypass the overlap guard to simulate bad data

    result = resolve
    expect(result).to be_ambiguous
    expect(result.fee_rule).to be_nil
    expect(result.candidates.size).to eq(2)
  end

  it "respects effective dates" do
    create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0088"),
                      effective_from: Time.zone.local(2026, 1, 1), effective_until: Time.zone.local(2026, 10, 1))
    new_rule = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0110"),
                                 effective_from: Time.zone.local(2026, 10, 1))
    expect(resolve.fee_rule).to eq(new_rule)
    expect(resolve(time: Time.zone.local(2026, 9, 30)).fee_rule.base_fee_rate).to eq(BigDecimal("0.0088"))
  end

  it "does not apply rules targeted at another merchant or dealer" do
    create(:fee_rule, merchant: create(:merchant))
    create(:fee_rule, dealer: create(:dealer))
    expect(resolve.status).to eq(:not_found)
  end

  it "is not found without a transaction time" do
    create(:fee_rule)
    expect(resolve(time: nil).status).to eq(:not_found)
  end
end
