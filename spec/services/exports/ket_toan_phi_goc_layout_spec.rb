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

  # Price the row the way the app does, so the stored rates and snapshot are the real ones.
  def priced(card_type:)
    transaction = transaction_with(card_type: card_type)
    Transactions::Recalculator.call(transaction, resolve: true)
    transaction.save!
    transaction
  end

  describe ".partition" do
    it "puts an MB row on the household sheet and prices it from the card rule" do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
      mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = priced(card_type: mb_card)

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
      transaction = priced(card_type: mb_card)

      placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to be_empty
      expect(placed.first.sheet_name).to eq("1,17")
      expect(placed.first.formula_percent).to eq("0.90%")
      expect(placed.first.dealer_rate).to eq(BigDecimal("0.011"))
    end

    it "uses the rule base fee as the sheet and the card base fee in the formula" do
      create(:fee_rule, merchant: merchant, card_type: napas_card, base_fee_rate: BigDecimal("0.0121"),
        card_base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = priced(card_type: napas_card)

      placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to be_empty
      expect(placed.first.sheet_name).to eq("1,21")
      expect(placed.first.formula_percent).to eq("0.88%")
      expect(placed.first.dealer_rate).to eq(BigDecimal("0.012"))
      expect(transaction.applied_base_fee_rate).to eq(BigDecimal("0.0121"))
    end

    it "matches the stored transaction when a household rule lists the card without a card base fee" do
      create(:fee_rule, merchant: merchant, card_type: mb_card, base_fee_rate: BigDecimal("0.0121"),
        dealer_rate: BigDecimal("0.014"))
      mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = Transactions::Builder.call(bill_image: analyzed_bill(extraction: "mb_settlement", caption: "MB")).sole

      placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to be_empty
      expect(placed.first.sheet_name).to eq("1,21")
      expect(placed.first.formula_percent).to eq("1.21%")
      expect(placed.first.dealer_rate).to eq(transaction.applied_dealer_rate)
      expect(transaction.amount_after_base_fee_vnd).to eq(9_879_000)
    end

    it "prices MB and Napas from one rule that lists both cards" do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
      create(:fee_rule, card_types: [ mb_card, napas_card ], base_fee_rate: BigDecimal("0.0088"),
        dealer_rate: BigDecimal("0.012"), priority: 40)
      mb_transaction = priced(card_type: mb_card)
      napas_transaction = priced(card_type: napas_card)

      placed, skipped = described_class.partition([ mb_transaction, napas_transaction ])

      expect(skipped).to be_empty
      expect(placed.map(&:sheet_name)).to eq([ "1,21", "1,21" ])
      expect(placed.map(&:formula_percent)).to eq([ "0.88%", "0.88%" ])
      expect(placed.map(&:dealer_rate)).to all(eq(BigDecimal("0.012")))
      expect(mb_transaction.applied_base_fee_rate).to eq(BigDecimal("0.0121"))
    end

    it "prices a Napas row from the Napas card rule" do
      create(:fee_rule, merchant: merchant, card_type: normal_card, base_fee_rate: BigDecimal("0.0115"))
      create(:fee_rule, card_type: napas_card, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = priced(card_type: napas_card)

      placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to be_empty
      expect(placed.first.sheet_name).to eq("1,15")
      expect(placed.first.formula_percent).to eq("0.88%")
      expect(placed.first.dealer_rate).to eq(BigDecimal("0.012"))
    end

    it "skips MB when the merchant has no tier rule" do
      mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = priced(card_type: mb_card)

      _placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to eq([ { "transaction_id" => transaction.id, "reason" => "sheet_unmapped" } ])
    end

    it "uses the dealer rate stored on the transaction" do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
      transaction = priced(card_type: mb_card)

      placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to be_empty
      expect(placed.first.dealer_rate).to eq(BigDecimal("0.014"))
    end

    it "skips MB when the transaction has no dealer rate" do
      create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: nil)
      transaction = priced(card_type: mb_card)

      _placed, skipped = described_class.partition([ transaction ])

      expect(skipped).to eq([ { "transaction_id" => transaction.id, "reason" => "dealer_rate_missing" } ])
    end

    it "keeps the saved rates when a fee rule is edited after the transaction was priced" do
      household = create(:fee_rule, merchant: merchant, card_type: mb_card, base_fee_rate: BigDecimal("0.0121"),
        card_base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = priced(card_type: mb_card)

      household.update!(base_fee_rate: BigDecimal("0.0117"), card_base_fee_rate: BigDecimal("0.0090"),
        dealer_rate: BigDecimal("0.011"))
      placed, skipped = described_class.partition([ transaction.reload ])

      expect(skipped).to be_empty
      expect(placed.first.sheet_name).to eq("1,21")
      expect(placed.first.formula_percent).to eq("0.88%")
      expect(placed.first.dealer_rate).to eq(BigDecimal("0.012"))
    end

    it "keeps the saved household sheet when a card-only rule priced the row and the household rule changes later" do
      household = create(:fee_rule, merchant: merchant, card_type: normal_card, base_fee_rate: BigDecimal("0.0115"))
      create(:fee_rule, card_type: napas_card, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = priced(card_type: napas_card)

      household.update!(base_fee_rate: BigDecimal("0.0121"))
      placed, = described_class.partition([ transaction.reload ])

      expect(placed.first.sheet_name).to eq("1,15")
    end

    it "keeps the saved household sheet after a recalculation from the snapshot" do
      create(:fee_rule, merchant: merchant, card_type: normal_card, base_fee_rate: BigDecimal("0.0115"))
      create(:fee_rule, card_type: napas_card, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
      transaction = priced(card_type: napas_card)

      Transactions::Recalculator.call(transaction, resolve: false)
      transaction.save!
      FeeRule.joins(:fee_rule_merchants).update_all(active: false)
      placed, = described_class.partition([ transaction.reload ])

      expect(placed.first.sheet_name).to eq("1,15")
    end
  end
end
