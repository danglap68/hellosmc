require "rails_helper"

RSpec.describe "Transaction review actions" do
  include_context "accounting setup"

  let(:operator) { create(:user, :operator) }
  let(:transaction) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }

  describe Transactions::Corrector do
    it "applies corrections, recalculates and audits before/after" do
      result = described_class.call(
        transaction: transaction, actor: operator, note: "đọc lại bill",
        params: { transaction_amount_vnd: "10.000.000", lot_number: "000300", merchant_id: merchant.id,
                  dealer_id: dealer.id, card_type_id: mb_card.id, transaction_date: "2026-10-04", transaction_time: "09:30:00" }
      )

      expect(result).to be_success
      transaction.reload
      expect(transaction.transaction_amount_vnd).to eq(10_000_000)
      expect(transaction.applied_base_fee_rate).to eq(BigDecimal("0.011"))
      expect(transaction.amount_after_base_fee_vnd).to eq(9_890_000)
      expect(transaction).to be_needs_review

      audit = AuditLog.find_by!(action: "transaction.corrected", auditable: transaction)
      expect(audit.actor_user).to eq(operator)
      expect(audit.before_data["transaction_amount_vnd"]).to eq(11_445_000)
      expect(audit.after_data["transaction_amount_vnd"]).to eq(10_000_000)
      expect(audit.metadata["note"]).to eq("đọc lại bill")
      expect(transaction.open_review.corrected_values["transaction_amount_vnd"]).to eq(10_000_000)
    end

    it "rejects malformed amounts and times" do
      result = described_class.call(transaction: transaction, actor: operator,
                                    params: { transaction_amount_vnd: "abc", transaction_date: "2026-13-40", transaction_time: "x" })
      expect(result).not_to be_success
      expect(transaction.errors[:transaction_amount_vnd]).to be_present
      expect(transaction.errors[:transaction_at]).to be_present
    end

    it "uses an explicit fee rule override when given" do
      override = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.014"))
      described_class.call(transaction: transaction, actor: operator, params: { fee_rule_id: override.id, merchant_id: merchant.id })
      expect(transaction.reload.fee_rule).to eq(override)
      expect(transaction.calculation_data["fee_rule_source"]).to eq("override")
    end

    it "refuses to edit an approved transaction" do
      approved = Transactions::Builder.call(bill_image: analyzed_bill(extraction: "napas_settlement")).sole
      expect(approved).to be_approved
      expect(described_class.call(transaction: approved, actor: operator, params: { lot_number: "1" })).not_to be_success
    end
  end

  describe Transactions::Approver do
    it "recalculates and approves a complete transaction" do
      Transactions::Corrector.call(transaction: transaction, actor: operator, params: { merchant_id: merchant.id })
      expect(described_class.call(transaction: transaction, actor: operator, note: "ok")).to be(true)

      transaction.reload
      expect(transaction).to be_approved
      expect(transaction.approved_by).to eq(operator)
      expect(transaction.amount_after_base_fee_vnd).to eq(11_344_284)
      expect(transaction.reviews.where(status: "approved", reviewed_by: operator)).to exist
      expect(AuditLog.where(action: "transaction.approved", actor_id: operator.id)).to exist
    end

    it "refuses incomplete transactions" do
      transaction.update!(merchant: nil)
      expect(described_class.call(transaction: transaction, actor: operator)).to be(false)
      expect(transaction.errors[:merchant]).to be_present
      expect(transaction.reload).to be_needs_review
    end

    it "refuses when no fee rule applies" do
      FeeRule.update_all(active: false)
      expect(described_class.call(transaction: transaction, actor: operator)).to be(false)
      expect(transaction.errors[:fee_rule]).to be_present
    end
  end

  describe Transactions::StatusUpdater do
    it "holds and later allows approval from hold" do
      expect(described_class.call(transaction: transaction, actor: operator, action: "hold", note: "chờ đối soát")).to be(true)
      expect(transaction.reload).to be_hold
      expect(AuditLog.where(action: "transaction.held")).to exist
      expect(Transactions::Approver.call(transaction: transaction, actor: operator)).to be(true)
    end

    it "rejects terminally" do
      described_class.call(transaction: transaction, actor: operator, action: "reject")
      expect(transaction.reload).to be_rejected
      expect(described_class.call(transaction: transaction, actor: operator, action: "hold")).to be(false)
    end
  end

  describe Transactions::Reprocessor do
    it "moves the transaction to processing and re-enqueues OCR" do
      expect(described_class.call(transaction: transaction, actor: operator)).to be(true)
      expect(transaction.reload).to be_processing
      expect(AnalyzeBillImageJob).to have_been_enqueued.with(transaction.bill_image_id, force: true)
    end
  end
end

RSpec.describe "Concurrent review decisions" do
  include_context "accounting setup"

  let(:operator) { create(:user, :operator) }
  let!(:transaction) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }

  it "does not approve a transaction another reviewer rejected meanwhile" do
    stale_copy = Transaction.find(transaction.id)
    Transactions::StatusUpdater.call(transaction: transaction, actor: operator, action: "reject")

    expect(Transactions::Approver.call(transaction: stale_copy, actor: operator)).to be(false)
    expect(transaction.reload).to be_rejected
  end

  it "rejects corrections made from an outdated form" do
    rendered_version = transaction.lock_version
    Transactions::Corrector.call(transaction: Transaction.find(transaction.id), actor: operator, params: { lot_number: "1" })

    result = Transactions::Corrector.call(transaction: transaction, actor: operator,
                                          params: { lot_number: "2", lock_version: rendered_version })
    expect(result).not_to be_success
    expect(transaction.reload.lot_number).to eq("1")
  end

  it "keeps the snapshotted rate when nothing that drives the rate changed" do
    default_rule.update!(base_fee_rate: BigDecimal("0.02"))
    Transactions::Corrector.call(transaction: transaction, actor: operator, params: { lot_number: "000555" })
    expect(transaction.reload.applied_base_fee_rate).to eq(BigDecimal("0.0088"))

    Transactions::Approver.call(transaction: transaction, actor: operator)
    expect(transaction.reload.applied_base_fee_rate).to eq(BigDecimal("0.0088"))
  end

  it "re-resolves the rate when the card type changes" do
    Transactions::Corrector.call(transaction: transaction, actor: operator, params: { card_type_id: mb_card.id })
    expect(transaction.reload.applied_base_fee_rate).to eq(BigDecimal("0.011"))
  end
end

RSpec.describe "Edited Telegram captions" do
  include_context "accounting setup"

  it "puts booked transactions on hold when the card-type tag changes" do
    chat.update!(telegram_chat_id: -1001234567890)
    update = telegram_fixture("photo_update")
    Telegram::UpdateReceiver.call(update)
    message = TelegramMessage.last
    bill_image = create(:bill_image, :analyzed, telegram_message: message, extraction: "mb_settlement")
    transaction = Transactions::Builder.call(bill_image: bill_image).sole
    expect(transaction).to be_approved
    expect(transaction.card_type).to eq(mb_card)

    Telegram::UpdateReceiver.call("update_id" => 900003, "edited_message" => update["message"].merge("caption" => "Napas"))

    expect(transaction.reload).to be_hold
    expect(transaction.review_reason_codes).to include("caption_edited")
    expect(AuditLog.where(action: "transaction.flagged", auditable: transaction)).to exist
  end

  it "ignores edits that do not change the tags" do
    chat.update!(telegram_chat_id: -1001234567890)
    update = telegram_fixture("photo_update")
    Telegram::UpdateReceiver.call(update)
    transaction = Transactions::Builder.call(bill_image: create(:bill_image, :analyzed, telegram_message: TelegramMessage.last,
                                                                                         extraction: "mb_settlement")).sole

    Telegram::UpdateReceiver.call("update_id" => 900004, "edited_message" => update["message"].merge("caption" => "mb nhé"))
    expect(transaction.reload).to be_approved
  end
end
