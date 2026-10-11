require "rails_helper"

RSpec.describe Transaction do
  describe "state machine" do
    it "allows needs_review -> approved" do
      transaction = create(:transaction, :calculated, status: "needs_review")
      transaction.transition_to!("approved", approved_at: Time.current)
      expect(transaction.reload).to be_approved
    end

    it "refuses arbitrary transitions" do
      transaction = create(:transaction, status: "needs_review")
      expect { transaction.transition_to!("exported") }.to raise_error(Transaction::InvalidTransition)
      expect(transaction.reload).to be_needs_review
    end

    it "treats rejected as terminal" do
      expect(Transaction::TRANSITIONS["rejected"]).to be_empty
    end

    it "covers every status" do
      expect(Transaction::TRANSITIONS.keys).to match_array(Transaction::STATUSES)
    end
  end

  describe "validations" do
    it "requires complete accounting values when approved" do
      transaction = build(:transaction, status: "approved", applied_base_fee_rate: nil, amount_after_base_fee_vnd: nil)
      expect(transaction).not_to be_valid
      expect(transaction.errors[:applied_base_fee_rate]).to be_present
    end

    it "allows incomplete values while in review" do
      expect(build(:transaction, status: "needs_review", merchant: nil, transaction_amount_vnd: nil)).to be_valid
    end

    it "stores VND as an integer" do
      transaction = build(:transaction, transaction_amount_vnd: 10_000.5)
      expect(transaction).not_to be_valid
    end

    it "is protected by a database constraint for finalized rows" do
      transaction = create(:transaction, status: "needs_review")
      expect {
        transaction.update_columns(status: "approved")
      }.to raise_error(ActiveRecord::StatementInvalid, /transactions_approved_complete/)
    end
  end

  describe "#base_fee_rate_used" do
    it "is the card base fee when one applied, else the base fee" do
      transaction = build(:transaction, applied_base_fee_rate: BigDecimal("0.0121"), applied_card_base_fee_rate: BigDecimal("0.0088"))
      expect(transaction.base_fee_rate_used).to eq(BigDecimal("0.0088"))

      transaction.applied_card_base_fee_rate = nil
      expect(transaction.base_fee_rate_used).to eq(BigDecimal("0.0121"))
    end
  end

  it "uses bigint money columns and decimal rates" do
    columns = Transaction.columns_hash
    expect(columns["transaction_amount_vnd"].sql_type).to eq("bigint")
    expect(columns["amount_after_base_fee_vnd"].sql_type).to eq("bigint")
    expect(columns["applied_base_fee_rate"].sql_type).to eq("numeric(10,6)")
  end
end
