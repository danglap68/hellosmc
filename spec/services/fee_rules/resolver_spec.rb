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

  it "applies one card rule to every card type listed on it" do
    napas = create(:napas_card_type)
    shared = create(:fee_rule, card_types: [ mb, napas ], base_fee_rate: BigDecimal("0.0088"))

    expect(resolve.fee_rule).to eq(shared)
    expect(resolve(card_type: napas).fee_rule).to eq(shared)
    expect(resolve(card_type: normal).fee_rule).not_to eq(shared)
  end

  it "applies one rule to every household listed on it" do
    other = create(:merchant, dealer: dealer)
    shared = create(:fee_rule, merchants: [ merchant, other ], base_fee_rate: BigDecimal("0.0121"))

    expect(resolve.fee_rule).to eq(shared)
    expect(resolve(merchant: other).fee_rule).to eq(shared)
    expect(resolve(merchant: create(:merchant, dealer: dealer)).status).to eq(:not_found)
  end

  it "does not apply rules targeted at another merchant or dealer" do
    create(:fee_rule, merchant: create(:merchant))
    create(:fee_rule, dealer: create(:dealer))
    expect(resolve.status).to eq(:not_found)
  end

  it "uses the household base fee when the card is not listed and no other rule lists it" do
    household = create(:fee_rule, merchant: merchant, card_type: mb, base_fee_rate: BigDecimal("0.0121"),
                                  card_base_fee_rate: BigDecimal("0.0088"))

    base_fee = described_class.amount_base_fee(rule: household, merchant: merchant, dealer: dealer, card_type: normal, at: at)

    expect(base_fee.rate).to eq(BigDecimal("0.0121"))
    expect(base_fee.rule).to eq(household)
    expect(base_fee.card_rate).to be_nil
  end

  it "uses its own card base fee, else its own base fee, when the household rule lists the card" do
    mb_rule = create(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
    with_card_fee = create(:fee_rule, merchant: merchant, card_type: mb, base_fee_rate: BigDecimal("0.0121"),
                                      card_base_fee_rate: BigDecimal("0.0090"))
    args = { merchant: merchant, dealer: dealer, card_type: mb, at: at }

    own = described_class.amount_base_fee(rule: with_card_fee, **args)
    expect([ own.rate, own.rule, own.card_rate ]).to eq([ BigDecimal("0.0090"), with_card_fee, BigDecimal("0.0090") ])

    with_card_fee.update!(card_base_fee_rate: nil)
    plain = described_class.amount_base_fee(rule: with_card_fee.reload, **args)
    expect([ plain.rate, plain.rule, plain.card_rate ]).to eq([ BigDecimal("0.0121"), with_card_fee, nil ])
    expect(mb_rule).to be_persisted
  end

  it "reads the MB rule when the household rule has no card base fee" do
    create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    mb_rule = create(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))

    expect(resolve.fee_rule).not_to eq(mb_rule)
    expect(described_class.explicit_card_rule(merchant: merchant, dealer: dealer, card_type: mb, at: at)).to eq(mb_rule)
  end

  it "prefers a card rule configured with the household over a card-only rule with the same priority" do
    household = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"))
    card_only = create(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0088"), priority: 100)
    args = { merchant: merchant, dealer: dealer, card_type: mb, at: at }

    expect(described_class.explicit_card_rule(**args, except: household)).to eq(card_only)

    household_card = create(:fee_rule, merchant: merchant, card_type: mb, base_fee_rate: BigDecimal("0.0095"),
                                       priority: 100)

    expect(described_class.explicit_card_rule(**args, except: household)).to eq(household_card)
  end

  it "does not allow two active rules to tie for the same household and card type" do
    create(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0088"), priority: 100)
    tie = build(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0090"), priority: 100)

    expect(tie).not_to be_valid
    expect(tie.errors[:base]).to be_present
  end

  it "takes the dealer rate from the rule that gave the base fee" do
    household = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    mb_rule = create(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
    args = { rule: household, merchant: merchant, dealer: dealer, at: at }

    borrowed = described_class.amount_base_fee(card_type: mb, **args)
    expect([ borrowed.rule, borrowed.dealer_rate, borrowed.card_rate ]).to eq([ mb_rule, BigDecimal("0.012"), BigDecimal("0.0088") ])

    mb_rule.update!(dealer_rate: nil)
    expect(described_class.amount_base_fee(card_type: mb, **args).dealer_rate).to eq(BigDecimal("0.014"))
    expect(described_class.amount_base_fee(card_type: normal, **args).dealer_rate).to eq(BigDecimal("0.014"))
  end

  it "uses the oldest card rule and flags a tie when two card rules are equally specific" do
    household = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"))
    first = create(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0088"), priority: 100)
    second = build(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0090"), priority: 100)
    second.save!(validate: false)

    base_fee = described_class.amount_base_fee(rule: household, merchant: merchant, dealer: dealer, card_type: mb, at: at)

    expect(base_fee.review_reason).to eq("card_fee_rule_ambiguous")
    expect(base_fee.rule).to eq(first)
    expect(base_fee.rate).to eq(BigDecimal("0.0088"))
    expect(second.id).to be > first.id
  end

  it "does not flag a tie when a household card rule beats a card-only rule" do
    household = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"))
    create(:fee_rule, card_type: mb, base_fee_rate: BigDecimal("0.0088"), priority: 100)
    with_household = create(:fee_rule, merchant: merchant, card_type: mb, base_fee_rate: BigDecimal("0.0095"), priority: 100)

    base_fee = described_class.amount_base_fee(rule: household, merchant: merchant, dealer: dealer, card_type: mb, at: at)

    expect(base_fee.review_reason).to be_nil
    expect(base_fee.rule).to eq(with_household)
  end

  it "keeps the household base fee and asks for review when another rule lists a card that cannot borrow" do
    household = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    create(:fee_rule, card_type: normal, base_fee_rate: BigDecimal("0.0100"), dealer_rate: BigDecimal("0.013"))

    base_fee = described_class.amount_base_fee(rule: household, merchant: merchant, dealer: dealer, card_type: normal, at: at)

    expect(base_fee.rate).to eq(BigDecimal("0.0121"))
    expect(base_fee.rule).to eq(household)
    expect(base_fee.card_rate).to be_nil
    expect(base_fee.dealer_rate).to eq(BigDecimal("0.014"))
    expect(base_fee.review_reason).to eq("card_fee_rule_not_applied")
  end

  it "does not ask for review when nothing else lists the card" do
    household = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"))

    base_fee = described_class.amount_base_fee(rule: household, merchant: merchant, dealer: dealer, card_type: normal, at: at)

    expect(base_fee.rate).to eq(BigDecimal("0.0121"))
    expect(base_fee.review_reason).to be_nil
  end

  it "is not found without a transaction time" do
    create(:fee_rule)
    expect(resolve(time: nil).status).to eq(:not_found)
  end
end
