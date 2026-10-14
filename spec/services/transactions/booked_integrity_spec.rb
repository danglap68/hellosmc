require "rails_helper"

RSpec.describe "Booked transaction integrity" do
  let(:actor) { create(:user, :operator) }
  let(:transaction) { create(:transaction, :approved) }
  let!(:entry) do
    WorkbookEntry.create!(recorded_transaction: transaction, spreadsheet_id: "test-sheet",
                          branch: "identified", amount_vnd: transaction.transaction_amount_vnd)
  end

  it "refuses hold/reject after posting and leaves the accounting status intact" do
    expect(Transactions::StatusUpdater.call(transaction: transaction, actor: actor, action: "hold")).to be(false)
    expect(transaction.errors[:base]).to include(I18n.t("errors.messages.already_booked"))
    expect(transaction.reload).to be_approved
    expect(AuditLog.where(auditable: transaction, action: "transaction.held")).not_to exist
  end

  it "blocks editing, retrying OCR and rejecting a legacy held bill that was already posted" do
    Transactions::Flagger.call(transactions: [ transaction ], reason: "caption_edited")
    expect(transaction.reload).to be_hold
    expect(transaction).not_to be_editable
    expect(transaction).not_to be_reprocessable
    expect(Transactions::Corrector.call(transaction: transaction, actor: actor, params: { transaction_amount_vnd: "20000000" })).not_to be_success
    expect(Transactions::Reprocessor.call(transaction: transaction, actor: actor)).to be(false)
    expect(Transactions::StatusUpdater.call(transaction: transaction, actor: actor, action: "reject", note: "Wrong amount")).to be(false)
    expect(transaction.reload.transaction_amount_vnd).to eq(entry.amount_vnd)
    expect(transaction).to be_hold
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "protects posted monetary values and identity even if another path bypasses Corrector" do
    {
      transaction_amount_vnd: 20000000, lot_number: "changed", transaction_at: 1.day.ago,
      dealer_id: create(:dealer).id, merchant_id: create(:merchant).id,
      card_type_id: create(:card_type).id, applied_base_fee_rate: BigDecimal("0.5"),
      amount_after_base_fee_vnd: 123, applied_dealer_rate: BigDecimal("0.1"),
      applied_card_base_fee_rate: BigDecimal("0.1"), dealer_amount_vnd: 123, profit_amount_vnd: 123
    }.each do |field, value|
      expect(transaction.update(field => value)).to be(false), "expected #{field} to be immutable"
      transaction.reload
    end
    expect(transaction.transaction_amount_vnd).to eq(entry.amount_vnd)
  end

  it "does not let a cached missing association bypass the guard" do
    unposted = create(:transaction, :hold)
    expect(unposted.workbook_entry).to be_nil
    WorkbookEntry.create!(recorded_transaction: unposted, spreadsheet_id: "test-sheet", branch: "identified", amount_vnd: unposted.transaction_amount_vnd)
    expect(Transactions::Corrector.call(transaction: unposted, actor: actor, params: { lot_number: "changed" })).not_to be_success
    expect(unposted.reload.lot_number).to eq("000269")
  end
end
