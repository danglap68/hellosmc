require "rails_helper"

RSpec.describe "Payment QR decisions" do
  include_context "payment QR setup"

  def confirm(amount = nil, version: payment_qr.lock_version)
    PaymentQrs::Decide.call(request: payment_qr, decision: "confirm", amount: amount, version: version)
  end

  it "prepares a draft without generating a QR or sending Telegram" do
    expect { payment_qr }.not_to have_enqueued_job(DeliverPaymentQrJob)
    expect(payment_qr).to be_pending
    expect(payment_qr.qr_payload).to be_nil
    expect(payment_qr.snapshot).to include("transfer_code" => "AS2", "dealer_amount_vnd" => 9_860_000)
    expect(PaymentQrs::Prepare.call(payment_transaction)).to eq(payment_qr)
  end

  it "uses net dealer amount and exact code, preserving leading account zeroes" do
    confirm
    expect(payment_qr).to be_confirmed
    expect(payment_qr.transfer_amount_vnd).to eq(9_860_000)
    expect(payment_qr.qr_payload).to include("0112076802960001", "54079860000", "0803AS2")
  end

  it "audits a payout correction without changing the bill, fees or workbook" do
    payment_qr
    before = payment_transaction.reload.attributes
    actor = create(:user, :admin)
    expect do
      PaymentQrs::Decide.call(request: payment_qr, decision: "confirm", amount: "79197000",
                             version: payment_qr.lock_version, actor: actor)
    end.not_to have_enqueued_job(WriteHelloSmcWorkbookJob)
    expect(payment_transaction.reload.attributes).to eq(before)
    expect(payment_qr.transfer_amount_vnd).to eq(79_197_000)
    audit = AuditLog.find_by!(action: "payment_qr.confirmed")
    expect(audit.actor_id).to eq(actor.id)
    expect(audit.metadata).to include("original_amount_vnd" => 9_860_000, "confirmed_amount_vnd" => 79_197_000)
    expect(audit.after_data).not_to have_key("access_token")
  end

  it "handles double submit idempotently and refuses conflicting decisions" do
    version = payment_qr.lock_version
    confirm("100000", version: version)
    expect { confirm("100000", version: version) }.not_to change { AuditLog.where(action: "payment_qr.confirmed").count }
    expect { confirm("200000", version: version) }.to raise_error(PaymentQrs::Error, /đã được xử lý/)
  end

  it "rejects invalid amounts and stale forms" do
    %w[0 -1 1.5 79,197,000 1e5 10000000000000].each do |invalid|
      expect { confirm(invalid) }.to raise_error(PaymentQrs::Error, /số tiền VND/)
    end
    expect { confirm("100", version: -1) }.to raise_error(PaymentQrs::Error, /tải lại/)
    expect(payment_qr.reload).to be_pending
  end

  it "invalidates confirmation and PNG access when recipient, code or approval changes" do
    confirm
    expect(payment_qr).to be_current
    payment_dealer.update!(bank_account_number: "000111")
    expect(payment_qr).not_to be_current
    expect { confirm }.to raise_error(PaymentQrs::Error, /đã thay đổi/)
    previous_token = payment_qr.access_token
    PaymentQrs::Prepare.call(payment_transaction, refresh: true)
    expect(payment_qr.reload).to be_pending
    expect(payment_qr.access_token).not_to eq(previous_token)
    expect(payment_qr.qr_payload).to be_nil
    payment_link.update!(transfer_code: "AS3")
    expect(payment_qr).not_to be_current
    PaymentQrs::Prepare.call(payment_transaction, refresh: true)
    payment_transaction.transition_to!("hold")
    expect(payment_qr).not_to be_current
  end

  it "blocks ambiguous TIDs instead of guessing a code, but accepts the recorded resolved TID" do
    second = create(:merchant_dealer, merchant: payment_transaction.merchant, dealer: payment_dealer,
                     tid_key: "tid3", transfer_code: "AS3")
    expect(payment_qr).to be_blocked
    expect(payment_qr.issue).to include("duy nhất")
    payment_transaction.update!(source_data: { "dealer_resolution" => { "merchant_dealer_id" => second.id } })
    qr = PaymentQrs::Prepare.call(payment_transaction, refresh: true)
    expect(qr.snapshot.fetch("transfer_code")).to eq("AS3")
  end

  it "records missing bank details without breaking an approved bill" do
    payment_dealer.update!(auto_payment_qr: false, bank_bin: nil, bank_account_number: nil, bank_account_name: nil)
    expect(payment_qr).to be_blocked
    expect(payment_qr.issue).to include("ngân hàng")
    expect(payment_transaction.reload).to be_approved
  end

  it "cancels without a QR and requires explicit refresh for a new decision" do
    PaymentQrs::Decide.call(request: payment_qr, decision: "cancel", version: payment_qr.lock_version)
    expect(payment_qr.reload).to be_cancelled
    expect(payment_qr.qr_payload).to be_nil
    expect { confirm }.to raise_error(PaymentQrs::Error)
  end
end
