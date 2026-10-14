require "rails_helper"

RSpec.describe Transactions::DuplicateDetector do
  let(:merchant) { create(:merchant) }
  let(:dealer) { create(:dealer) }
  let(:at) { Time.zone.local(2026, 10, 4, 10, 57, 25) }
  let!(:existing) { create(:transaction, :approved, merchant: merchant, dealer: dealer, transaction_at: at, lot_number: "000269") }

  def candidate(**attributes)
    build(:transaction, { merchant: merchant, dealer: dealer, transaction_at: at, lot_number: "000269",
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

  it "flags the same settlement identity even when OCR read a different amount" do
    extraction = { "document_type" => "settlement", "terminal_or_merchant_id" => "106-C-067826" }
    existing.update!(source_data: { "extraction" => extraction }, lot_number: "000226",
                     transaction_amount_vnd: 261_180_000)
    other = candidate(lot_number: "000226", transaction_amount_vnd: 26_418_000,
                      source_data: { "extraction" => extraction.merge("terminal_or_merchant_id" => "106 C 067826") })
    expect(described_class.call(other).possible_duplicate_ids).to eq([ existing.id ])
    other.source_data["extraction"]["terminal_or_merchant_id"] = "DIFFERENT-MID"
    expect(described_class.call(other)).not_to be_possible_duplicate
  end

  it "does not join different amounts using only a lot number or a nearby time" do
    existing.update!(source_data: { "extraction" => { "document_type" => "settlement", "terminal_or_merchant_id" => "MID1" } })
    other = candidate(transaction_amount_vnd: 1_000, source_data: existing.source_data.deep_dup,
                      transaction_at: at + 1.minute)
    expect(described_class.call(other)).not_to be_possible_duplicate
    other.transaction_at = at
    other.source_data["extraction"].delete("terminal_or_merchant_id")
    expect(described_class.call(other)).not_to be_possible_duplicate
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
