require "rails_helper"

RSpec.describe Transactions::DuplicateDetector do
  let(:merchant) { create(:merchant) }
  let(:at) { Time.zone.local(2026, 10, 4, 10, 57, 25) }
  let!(:existing) { create(:transaction, :approved, merchant: merchant, dealer: merchant.dealer, transaction_at: at, lot_number: "000269") }

  def candidate(**attributes)
    build(:transaction, { merchant: merchant, dealer: merchant.dealer, transaction_at: at, lot_number: "000269",
                          transaction_amount_vnd: existing.transaction_amount_vnd }.merge(attributes))
  end

  it "flags the same merchant, amount and near time" do
    result = described_class.call(candidate(transaction_at: at + 3.minutes, lot_number: nil))
    expect(result.possible_duplicate_ids).to eq([ existing.id ])
  end

  it "flags the same lot on the same day even hours apart" do
    expect(described_class.call(candidate(transaction_at: at + 5.hours))).to be_possible_duplicate
  end

  it "does not flag a different amount" do
    expect(described_class.call(candidate(transaction_amount_vnd: 1_000))).not_to be_possible_duplicate
  end

  it "does not flag far-apart transactions with different lots" do
    expect(described_class.call(candidate(transaction_at: at + 2.hours, lot_number: "000270"))).not_to be_possible_duplicate
  end

  it "ignores rejected transactions and itself" do
    existing.update_columns(status: "rejected")
    expect(described_class.call(candidate)).not_to be_possible_duplicate
    expect(described_class.call(existing.reload).possible_duplicate_ids).to be_empty
  end
end
