require "rails_helper"

RSpec.describe Transactions::Builder do
  include_context "accounting setup"

  it "auto-approves a confident, fully resolved settlement" do
    bill_image = analyzed_bill
    transaction = described_class.call(bill_image: bill_image).sole

    expect(transaction).to be_approved
    expect(transaction.approved_by).to be_nil
    expect(transaction.approved_at).to be_present
    expect(transaction).to have_attributes(
      dealer: dealer, merchant: merchant, card_type: normal_card, fee_rule: default_rule,
      lot_number: "000269", transaction_amount_vnd: 11_445_000,
      applied_base_fee_rate: BigDecimal("0.0088"), amount_after_base_fee_vnd: 11_344_284
    )
    expect(transaction.transaction_at).to eq(Time.zone.local(2026, 10, 4, 10, 57, 25))
    expect(transaction.calculation_data).to include("formula" => "transaction_amount * (1 - base_fee_rate)")
    expect(transaction.calculation_data.dig("fee_rule", "id")).to eq(default_rule.id)
    expect(AuditLog.where(auditable: transaction).pluck(:action)).to include("transaction.created", "transaction.approved")
    expect(bill_image.telegram_message.reload).to be_processing_processed
  end

  it "prices the amount from the MB rule when the household rule has no card base fee" do
    household = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))

    transaction = described_class.call(bill_image: analyzed_bill(extraction: "mb_settlement", caption: "MB")).sole

    expect(transaction.fee_rule).to eq(household)
    expect(transaction.applied_base_fee_rate).to eq(BigDecimal("0.0121"))
    expect(transaction.applied_dealer_rate).to eq(BigDecimal("0.012"))
    expect(transaction.applied_card_base_fee_rate).to eq(BigDecimal("0.0088"))
    expect(transaction.amount_after_base_fee_vnd).to eq(9_912_000)
    expect(transaction.dealer_amount_vnd).to eq(9_880_000)
    expect(transaction.profit_amount_vnd).to eq(32_000)
    expect(transaction.calculation_data.dig("base_fee_rule", "id")).to eq(mb_rule.id)
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to eq([ "card_fee_rule_applied" ])
  end

  it "keeps pricing from the card rate when recalculating from the snapshot" do
    create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
    transaction = described_class.call(bill_image: analyzed_bill(extraction: "mb_settlement", caption: "MB")).sole

    Transactions::Recalculator.call(transaction, resolve: false)

    expect(transaction.applied_base_fee_rate).to eq(BigDecimal("0.0121"))
    expect(transaction.amount_after_base_fee_vnd).to eq(9_912_000)
    expect(transaction.dealer_amount_vnd).to eq(9_880_000)
  end

  it "auto-approves a household rule when no card rate applies" do
    create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))

    transaction = described_class.call(bill_image: analyzed_bill).sole

    expect(transaction.applied_card_base_fee_rate).to be_nil
    expect(transaction).to be_approved
  end

  it "uses the household card base fee when that rule lists the card" do
    household = create(:fee_rule, merchant: merchant, card_type: mb_card, base_fee_rate: BigDecimal("0.0121"),
                                  card_base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.014"))

    transaction = described_class.call(bill_image: analyzed_bill(extraction: "mb_settlement", caption: "MB")).sole

    expect(transaction.fee_rule).to eq(household)
    expect(transaction.applied_base_fee_rate).to eq(BigDecimal("0.0121"))
    expect(transaction.applied_card_base_fee_rate).to eq(BigDecimal("0.0088"))
    expect(transaction.applied_dealer_rate).to eq(BigDecimal("0.014"))
    expect(transaction.amount_after_base_fee_vnd).to eq(9_912_000)
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to eq([ "card_fee_rule_applied" ])
  end

  it "prices from its own base fee and dealer rate when a household rule lists the card without a card base fee" do
    household = create(:fee_rule, merchant: merchant, card_type: mb_card, base_fee_rate: BigDecimal("0.0121"),
                                  dealer_rate: BigDecimal("0.014"))
    mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))

    transaction = described_class.call(bill_image: analyzed_bill(extraction: "mb_settlement", caption: "MB")).sole

    expect(transaction.fee_rule).to eq(household)
    expect(transaction.applied_card_base_fee_rate).to be_nil
    expect(transaction.applied_dealer_rate).to eq(BigDecimal("0.014"))
    expect(transaction.amount_after_base_fee_vnd).to eq(9_879_000)
    expect(transaction.dealer_amount_vnd).to eq(9_860_000)
    expect(transaction.calculation_data.dig("base_fee_rule", "id")).to eq(household.id)
    expect(transaction).to be_approved
  end

  it "keeps the base fee source and card rate after the reviewer approves" do
    create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
    transaction = described_class.call(bill_image: analyzed_bill(extraction: "mb_settlement", caption: "MB")).sole

    expect(Transactions::Approver.call(transaction: transaction, actor: create(:user, :operator))).to be(true)

    transaction.reload
    expect(transaction).to be_approved
    expect(transaction.calculation_data.dig("base_fee_rule", "id")).to eq(mb_rule.id)
    expect(transaction.calculation_data["card_base_fee_rate"]).to eq("0.0088")
  end

  it "does not add nil keys when approving a transaction without a card rate" do
    create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    transaction = described_class.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole

    expect(Transactions::Approver.call(transaction: transaction, actor: create(:user, :operator))).to be(true)

    expect(transaction.reload.calculation_data).not_to have_key("card_base_fee_rate")
  end

  it "uses the explicit MB tag from the Telegram message" do
    transaction = described_class.call(bill_image: analyzed_bill(extraction: "mb_settlement", caption: "MB")).sole

    expect(transaction.card_type).to eq(mb_card)
    expect(transaction.applied_base_fee_rate).to eq(BigDecimal("0.011"))
    expect(transaction.amount_after_base_fee_vnd).to eq(9_890_000)
    expect(transaction).to be_approved
  end

  it "sends low-confidence OCR to manual review with reasons" do
    transaction = described_class.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole

    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("amount_unreadable", "merchant_low_confidence")
    review = transaction.reviews.sole
    expect(review).to be_open
    expect(review.original_values["total_amount_vnd"]).to eq(11_445_000)
  end

  it "creates one transaction per settlement in the same image" do
    create(:merchant, name: "Cường Duyên 1", code: "CD1", dealer: create(:dealer, name: "Cường Duyên"))
    transactions = described_class.call(bill_image: analyzed_bill(extraction: "two_settlements"))

    expect(transactions.size).to eq(2)
    expect(transactions.map(&:source_index)).to eq([ 0, 1 ])
    expect(transactions.map(&:transaction_amount_vnd)).to eq([ 11_445_000, 5_000_000 ])
    expect(transactions.first).to be_approved
    # Second settlement's merchant belongs to another dealer than the chat's.
    expect(transactions.second).to be_needs_review
    expect(transactions.second.review_reason_codes).to include("merchant_dealer_mismatch")
  end

  it "is idempotent" do
    bill_image = analyzed_bill
    first = described_class.call(bill_image: bill_image)
    expect { described_class.call(bill_image: bill_image) }.not_to change(Transaction, :count)
    expect(described_class.call(bill_image: bill_image)).to eq(first)
  end

  it "never creates a merchant from OCR and sends unknown merchants to review" do
    merchant.update!(name: "Một tên hoàn toàn khác")
    expect {
      transaction = described_class.call(bill_image: analyzed_bill).sole
      expect(transaction).to be_needs_review
      expect(transaction.merchant).to be_nil
      expect(transaction.review_reason_codes).to include("merchant_not_found")
    }.not_to change(Merchant, :count)
  end

  it "requires review when the chat has no dealer" do
    chat.update!(dealer: nil)
    transaction = described_class.call(bill_image: analyzed_bill).sole
    expect(transaction.review_reason_codes).to include("dealer_unmapped")
  end

  it "requires review when tags conflict" do
    transaction = described_class.call(bill_image: analyzed_bill(caption: "MB Napas")).sole
    expect(transaction.card_type).to be_nil
    expect(transaction.review_reason_codes).to include("card_type_conflict")
  end

  it "requires review when the fee rule is ambiguous" do
    duplicate_rule = build(:fee_rule, base_fee_rate: BigDecimal("0.0125"))
    duplicate_rule.save!(validate: false)
    transaction = described_class.call(bill_image: analyzed_bill).sole
    expect(transaction.review_reason_codes).to include("fee_rule_ambiguous")
    expect(transaction.applied_base_fee_rate).to be_nil
  end

  it "flags possible duplicates from another image" do
    described_class.call(bill_image: analyzed_bill)
    second = described_class.call(bill_image: analyzed_bill).sole
    expect(second).to be_needs_review
    expect(second.review_reason_codes).to include("possible_duplicate")
    expect(second.source_data["possible_duplicate_ids"]).to be_present
  end

  it "skips confident child receipts" do
    bill_image = analyzed_bill(extraction: "child_receipt")
    expect(described_class.call(bill_image: bill_image)).to be_empty
    expect(bill_image.reload.metadata["skipped_child_receipts"]).to eq([ 0 ])
  end

  it "snapshots the applied rate: later rule changes do not alter the transaction" do
    transaction = described_class.call(bill_image: analyzed_bill).sole
    default_rule.update!(base_fee_rate: BigDecimal("0.02"))
    expect(transaction.reload.applied_base_fee_rate).to eq(BigDecimal("0.0088"))
    expect(transaction.amount_after_base_fee_vnd).to eq(11_344_284)
  end

  it "creates a failed placeholder when OCR failed" do
    bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                     ocr_status: "failed", processing_error: "boom")
    transaction = described_class.call(bill_image: bill_image).sole
    expect(transaction).to be_failed
    expect(transaction.dealer).to eq(dealer)
    expect(transaction.review_reason_codes).to eq([ "ocr_failed" ])
  end

  it "rebuilds a transaction that is being reprocessed" do
    bill_image = analyzed_bill(extraction: "blurry_settlement")
    transaction = described_class.call(bill_image: bill_image).sole
    transaction.transition_to!("processing")

    normalized = BillVision::Normalizer.call(extraction_fixture("normal_settlement"), provider: "openai", model: "gpt-test")
    bill_image.update!(normalized_extraction: normalized, ocr_status: "completed")
    rebuilt = described_class.call(bill_image: bill_image).sole

    expect(rebuilt.id).to eq(transaction.id)
    expect(rebuilt).to be_approved
    expect(transaction.reviews.pluck(:status)).to include("superseded")
    expect(AuditLog.where(auditable: transaction, action: "transaction.rebuilt")).to exist
  end
end

RSpec.describe Transactions::Builder, "reprocessing a multi-settlement image" do
  include_context "accounting setup"

  let!(:tran3) { create(:merchant, name: "Trân 3", code: "TRAN3", dealer: dealer) }

  def document(merchant_name:, amount:, time:, lot:)
    { "document_type" => "settlement", "total_amount_vnd" => amount, "lot_number" => lot,
      "transaction_date" => "2026-10-04", "transaction_time" => time, "merchant_name" => merchant_name,
      "terminal_or_merchant_id" => nil,
      "confidence" => BillVision::Prompt::FIELDS.index_with { 0.97 }.merge("terminal_or_merchant_id" => 0.0) }
  end

  let(:thien_kim_doc) { document(merchant_name: "HỘ KINH DOANH THIÊN KIM GV", amount: 5_000_000, time: "09:00:00", lot: "000100") }
  let(:tran3_doc) { document(merchant_name: "Trân 3", amount: 7_000_000, time: "09:30:00", lot: "000200") }

  def analyze(bill_image, documents)
    normalized = BillVision::Normalizer.call({ "documents" => documents }, provider: "openai", model: "gpt-test")
    bill_image.update!(normalized_extraction: normalized, ocr_status: normalized["requires_review"] ? "needs_review" : "completed")
  end

  let(:bill_image) do
    create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat), ocr_status: "completed")
  end

  before do
    analyze(bill_image, [ thien_kim_doc, tran3_doc.merge("confidence" => tran3_doc["confidence"].merge("total_amount_vnd" => 0.5)) ])
    described_class.call(bill_image: bill_image)
  end

  it "matches rebuilt rows by content when the model returns another order" do
    first, second = bill_image.transactions.order(:source_index).to_a
    expect(first).to be_approved
    expect(second).to be_needs_review

    second.transition_to!("processing")
    analyze(bill_image, [ tran3_doc, thien_kim_doc ])
    described_class.call(bill_image: bill_image)

    expect(bill_image.transactions.count).to eq(2)
    second.reload
    expect(second.merchant).to eq(tran3)
    expect(second.transaction_amount_vnd).to eq(7_000_000)
    expect(second).to be_needs_review
    expect(second.review_reason_codes).to include("reprocessed_multi_settlement")
    expect(first.reload).to be_approved
  end

  it "never auto-approves settlements that only appear after a reprocess" do
    second = bill_image.transactions.find_by!(source_index: 1)
    second.transition_to!("processing")
    extra = document(merchant_name: "Trân 3", amount: 9_000_000, time: "10:00:00", lot: "000300")
    analyze(bill_image, [ thien_kim_doc, tran3_doc, extra ])
    described_class.call(bill_image: bill_image)

    added = bill_image.transactions.find_by!(source_index: 2)
    expect(added).to be_needs_review
    expect(added.review_reason_codes).to include("document_added_after_reprocess")
  end
end
