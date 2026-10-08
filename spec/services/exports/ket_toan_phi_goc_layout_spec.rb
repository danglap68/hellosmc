require "rails_helper"

RSpec.describe Exports::KetToanPhiGocLayout do
  include_context "accounting setup"

  def transaction_with(**attrs)
    create(:transaction, :approved, dealer: dealer, merchant: merchant, card_type: normal_card,
      amount_after_base_fee_vnd: 1, transaction_amount_vnd: 10_000, **attrs)
  end

  describe ".canonical_percent" do
    it "accepts a rate that is already two decimal percent points" do
      expect(described_class.canonical_percent(BigDecimal("0.012100"))).to eq(BigDecimal("1.21"))
      expect(described_class.canonical_percent(BigDecimal("0.01211"))).to be_nil
    end
  end

  describe ".partition" do
    it "puts an MB row on the household sheet and prices it from the card rule" do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
      mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = transaction_with(card_type: mb_card, applied_base_fee_rate: BigDecimal("0.0121"),
        applied_dealer_rate: BigDecimal("0.014"))

      placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to be_empty
      expect(placed.first.sheet_name).to eq("1,21")
      expect(placed.first.formula_percent).to eq("0.88%")
      expect(placed.first.dealer_rate).to eq(BigDecimal("0.012"))
    end

    it "prefers a merchant card rule over the card-only rule" do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0117"))
      mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      create(:fee_rule, merchant: merchant, card_type: mb_card, base_fee_rate: BigDecimal("0.009"),
        dealer_rate: BigDecimal("0.011"))
      transaction = transaction_with(card_type: mb_card, applied_base_fee_rate: BigDecimal("0.0117"),
        applied_dealer_rate: BigDecimal("0.014"))

      placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to be_empty
      expect(placed.first.sheet_name).to eq("1,17")
      expect(placed.first.formula_percent).to eq("0.90%")
      expect(placed.first.dealer_rate).to eq(BigDecimal("0.011"))
    end

    it "prices a Napas row from the Napas card rule" do
      create(:fee_rule, merchant: merchant, card_type: normal_card, base_fee_rate: BigDecimal("0.0115"))
      create(:fee_rule, card_type: napas_card, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = transaction_with(card_type: napas_card, applied_base_fee_rate: BigDecimal("0.0115"),
        applied_dealer_rate: BigDecimal("0.014"))

      placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to be_empty
      expect(placed.first.sheet_name).to eq("1,15")
      expect(placed.first.formula_percent).to eq("0.88%")
      expect(placed.first.dealer_rate).to eq(BigDecimal("0.012"))
    end

    it "skips MB when the merchant has no tier rule" do
      mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = transaction_with(card_type: mb_card, applied_base_fee_rate: BigDecimal("0.0121"),
        applied_dealer_rate: BigDecimal("0.014"))

      _placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to eq([ { "transaction_id" => transaction.id, "reason" => "sheet_unmapped" } ])
    end

    it "skips MB when the card rule has no dealer rate" do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
      transaction = transaction_with(card_type: mb_card, applied_base_fee_rate: BigDecimal("0.0121"),
        applied_dealer_rate: BigDecimal("0.014"))

      _placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to eq([ { "transaction_id" => transaction.id, "reason" => "dealer_rate_missing" } ])
    end
  end
end
