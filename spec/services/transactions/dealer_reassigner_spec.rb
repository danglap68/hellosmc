require "rails_helper"

RSpec.describe Transactions::DealerReassigner do
  let(:merchant) { create(:merchant) }
  let(:old_dealer) { create(:dealer, name: "Hùng") }
  let(:new_dealer) { create(:dealer, name: "Lan") }
  let(:approver) { create(:user, :operator) }
  let(:approved_at) { Time.zone.local(2026, 10, 15, 9, 30) }
  let!(:fee_rule) { create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.0121")) }
  let!(:transaction) do
    create(:transaction, :approved, merchant: merchant, dealer: old_dealer, approved_by: approver, approved_at: approved_at,
           transaction_amount_vnd: 10_000_000, applied_base_fee_rate: BigDecimal("0.0088"),
           applied_dealer_rate: BigDecimal("0.0100"), dealer_amount_vnd: 9_900_000, profit_amount_vnd: 12_000)
  end

  def call(dealer: new_dealer)
    described_class.call(transaction: transaction, dealer: dealer, source: "writer")
  end

  it "moves the bill to the dealer, recalculates and keeps the approval" do
    expect(call).to be_success

    transaction.reload
    expect(transaction).to have_attributes(dealer: new_dealer, status: "approved", approved_by: approver, approved_at: approved_at)
    expect(transaction.applied_dealer_rate).to eq(BigDecimal("0.0121"))
    expect(transaction.dealer_amount_vnd).to eq(9_879_000)
  end

  it "audits the move and the correction" do
    call

    audit = AuditLog.find_by!(action: "transaction.dealer_reassigned", auditable: transaction)
    expect(audit.metadata).to include("source" => "writer", "from_dealer_id" => old_dealer.id, "to_dealer_id" => new_dealer.id)
    expect(AuditLog.where(action: "transaction.corrected", auditable: transaction)).to exist
  end

  it "does not queue the workbook write again" do
    expect { call }.not_to have_enqueued_job(WriteHelloSmcWorkbookJob)
  end

  it "does nothing when the bill already has that dealer" do
    expect(call(dealer: old_dealer)).to be_success
    expect(AuditLog.where(action: "transaction.dealer_reassigned")).to be_empty
  end

  it "refuses a bill already in the workbook" do
    WorkbookEntry.create!(recorded_transaction: transaction, spreadsheet_id: "sheet", amount_vnd: 10_000_000, branch: "identified")

    result = call

    expect(result).not_to be_success
    expect(result.reason).to eq("already_in_workbook")
    expect(transaction.reload.dealer).to eq(old_dealer)
  end

  it "refuses a bill that is not approved" do
    transaction.update!(status: "hold")

    expect(call.reason).to eq("not_approved")
    expect(transaction.reload.dealer).to eq(old_dealer)
  end

  it "leaves the bill as it was when the new dealer has no fee rule" do
    fee_rule.update!(active: false)

    result = call

    expect(result).not_to be_success
    expect(transaction.reload).to have_attributes(dealer: old_dealer, status: "approved", dealer_amount_vnd: 9_900_000)
    expect(AuditLog.where(action: "transaction.dealer_reassigned")).to be_empty
  end

  describe "payment QR request" do
    let(:old_dealer) { create(:dealer, name: "Hùng", **bank_profile) }
    let(:bank_profile) do
      { bank_bin: PaymentQrs::Banks.all.first.fetch("bin"), bank_account_number: "1234567890", bank_account_name: "NGUYEN VAN HUNG" }
    end
    let(:link) { create(:merchant_dealer, merchant: merchant, dealer: old_dealer, tid_key: "tid1", transfer_code: "CH01") }

    before do
      transaction.update!(source_data: transaction.source_data.merge("dealer_resolution" => { "merchant_dealer_id" => link.id }))
      PaymentQrs::Prepare.call(transaction)
    end

    it "blocks the old dealer's request when the new dealer has no bank profile" do
      request = DealerPaymentQr.find_by!(transaction_id: transaction.id)
      expect(request).to be_pending

      call

      request.reload
      expect(request.dealer).to eq(new_dealer)
      expect(request).to be_blocked
      expect(request.snapshot).to eq({})
    end

    it "refuses to move a bill whose QR was already confirmed, since the old dealer may be paid" do
      DealerPaymentQr.find_by!(transaction_id: transaction.id).update!(status: "confirmed")

      result = call

      expect(result.reason).to eq("payment_qr_confirmed")
      expect(transaction.reload.dealer).to eq(old_dealer)
      expect(DealerPaymentQr.find_by!(transaction_id: transaction.id)).to be_confirmed
    end

    it "points the request at the new dealer's account when it has one" do
      new_dealer.update!(bank_profile.merge(bank_account_name: "TRAN THI LAN"))
      link.update!(dealer: new_dealer)

      call

      request = DealerPaymentQr.find_by!(transaction_id: transaction.id)
      expect(request).to be_pending
      expect(request.snapshot).to include("dealer_id" => new_dealer.id, "account_name" => "TRAN THI LAN")
    end
  end
end
