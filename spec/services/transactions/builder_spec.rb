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
    expect(transaction).to be_approved
  end

  it "uses the oldest card rule and sends the transaction to review when two card rules tie" do
    create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    mb_rule.update!(base_fee_rate: BigDecimal("0.0088"), dealer_rate: BigDecimal("0.012"))
    build(:fee_rule, card_type: mb_card, base_fee_rate: BigDecimal("0.0090"), dealer_rate: BigDecimal("0.012"),
                     priority: mb_rule.priority).save!(validate: false)

    transaction = described_class.call(bill_image: analyzed_bill(extraction: "mb_settlement", caption: "MB")).sole

    expect(transaction.calculation_data.dig("base_fee_rule", "id")).to eq(mb_rule.id)
    expect(transaction.applied_card_base_fee_rate).to eq(BigDecimal("0.0088"))
    expect(transaction.review_reason_codes).to include("card_fee_rule_ambiguous")
    expect(transaction).to be_needs_review
  end

  it "prices a normal card from the household rule and asks for review when a normal-card rule also exists" do
    household = create(:fee_rule, merchant: merchant, base_fee_rate: BigDecimal("0.0121"), dealer_rate: BigDecimal("0.014"))
    create(:fee_rule, card_type: normal_card, base_fee_rate: BigDecimal("0.0100"), dealer_rate: BigDecimal("0.013"))

    transaction = described_class.call(bill_image: analyzed_bill).sole

    expect(transaction.fee_rule).to eq(household)
    expect(transaction.applied_card_base_fee_rate).to be_nil
    expect(transaction.amount_after_base_fee_vnd).to eq(11_306_516)
    expect(transaction.review_reason_codes).to include("card_fee_rule_not_applied")
    expect(transaction).to be_needs_review
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
    expect(transaction).to be_approved
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
    transaction = described_class.call(bill_image: analyzed_bill(extraction: "blurry_settlement", caption: "MB")).sole
    expect(transaction).to be_needs_review
    expect(transaction.applied_card_base_fee_rate).to eq(BigDecimal("0.0088"))

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
    cuong = create(:dealer, name: "Cường Duyên")
    cuong_merchant = create(:merchant, name: "Cường Duyên 1", code: "CD1")
    create(:merchant_dealer, merchant: cuong_merchant, dealer: cuong, tid_key: "tid1",
           ds_sheet_anchor: "Cường Duyên 1", ds_header: "Cường Duyên (tid1)", rd_agent_label: "Cường Duyên")
    transactions = described_class.call(bill_image: analyzed_bill(extraction: "two_settlements"))

    expect(transactions.size).to eq(2)
    expect(transactions.map(&:source_index)).to eq([ 0, 1 ])
    expect(transactions.map(&:transaction_amount_vnd)).to eq([ 11_445_000, 5_000_000 ])
    expect(transactions.first).to be_approved
    expect(transactions.second).to be_approved
  end

  it "resolves the agent from a bare space-separated terminal number" do
    cherry = create(:merchant, name: "CHERRY COFFE", code: "CHERRY")
    cherry.merchant_aliases.create!(alias_type: "receipt_name", alias: "CHERRY COFEE")
    cuong = create(:dealer, name: "Cường Duyên")
    create(:merchant_dealer, merchant: cherry, dealer: cuong, tid_key: "tid2")

    doc = { "document_type" => "settlement", "total_amount_vnd" => 52_023_000,
            "transaction_date" => "2026-10-09", "transaction_time" => "19:20:07",
            "merchant_name" => "CHERRY COFEE 2", "lot_number" => "000202",
            "terminal_or_merchant_id" => "106-C-098513",
            "confidence" => BillVision::Prompt::FIELDS.index_with { 0.97 } }
    normalized = BillVision::Normalizer.call({ "documents" => [ doc ] }, provider: "openai", model: "gpt-test")
    image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                normalized_extraction: normalized, ocr_status: "completed")

    transaction = described_class.call(bill_image: image).sole

    expect(transaction.merchant).to eq(cherry)
    expect(transaction.dealer).to eq(cuong)
    expect(transaction.review_reason_codes).not_to include("dealer_unmapped", "merchant_fuzzy_match")
  end

  it "keeps the fuzzy match from the stripped name instead of discarding it for the no-match full name" do
    gat = create(:merchant, name: "Gat Tan Day Coffe", code: "GTD")
    gat.merchant_aliases.create!(alias_type: "receipt_name", alias: "Gat Tan Day Coffee")
    cuong = create(:dealer, name: "Cường Duyên")
    create(:merchant_dealer, merchant: gat, dealer: cuong, tid_key: "tid2")

    # OCR misread "TAN" as "TẠM" and appended a bare "2"; the stripped name
    # ("GẮT TẠM ĐÂY COFFEE") fuzzy-matches the alias while the full name does not.
    doc = { "document_type" => "settlement", "total_amount_vnd" => 52_023_000,
            "transaction_date" => "2026-10-10", "transaction_time" => "20:44:23",
            "merchant_name" => "GẮT TẠM ĐÂY COFFEE 2", "lot_number" => "003327",
            "terminal_or_merchant_id" => "106-C-067826",
            "confidence" => BillVision::Prompt::FIELDS.index_with { 0.97 } }
    normalized = BillVision::Normalizer.call({ "documents" => [ doc ] }, provider: "openai", model: "gpt-test")
    image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                normalized_extraction: normalized, ocr_status: "completed")

    transaction = described_class.call(bill_image: image).sole

    expect(transaction.merchant).to eq(gat)
    expect(transaction.review_reason_codes).to include("merchant_fuzzy_match")
  end

  it "inherits the non-truncated, highest-confidence merchant name" do
    album = create(:bill_album, telegram_chat: chat)

    child = lambda do |merchant, confidence|
      { "document_type" => "child_receipt", "total_amount_vnd" => 100_000_000,
        "transaction_date" => "2026-10-04", "transaction_time" => "18:30:00",
        "merchant_name" => merchant, "lot_number" => "000078",
        "confidence" => BillVision::Prompt::FIELDS.index_with { 0.97 }.merge("merchant_name" => confidence) }
    end
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        normalized_extraction: BillVision::Normalizer.call({ "documents" => [ child.call("HỘ KINH DOANH THIÊN KIM...", 0.55) ] }, provider: "openai", model: "gpt-test"),
                        ocr_status: "completed")
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        normalized_extraction: BillVision::Normalizer.call({ "documents" => [ child.call("HỘ KINH DOANH THIÊN KIM", 0.72) ] }, provider: "openai", model: "gpt-test"),
                        ocr_status: "completed")

    settlement = { "document_type" => "settlement", "total_amount_vnd" => 100_000_000,
                   "transaction_date" => "2026-10-04", "transaction_time" => nil, "merchant_name" => nil,
                   "confidence" => BillVision::Prompt::FIELDS.index_with { 0.97 }.merge("merchant_name" => 0.0, "transaction_time" => 0.0) }
    settlement_image = create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                                           normalized_extraction: BillVision::Normalizer.call({ "documents" => [ settlement ] }, provider: "openai", model: "gpt-test"),
                                           ocr_status: "needs_review")

    transaction = described_class.call(bill_image: settlement_image).sole

    expect(transaction.source_data.dig("extraction", "merchant_name")).to eq("HỘ KINH DOANH THIÊN KIM")
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

  it "requires review when the merchant has no TID agent" do
    merchant_dealer_link.destroy!
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

  it "skips child receipts in an album (evidence only)" do
    bill_image = analyzed_bill(extraction: "child_receipt")
    bill_image.update!(bill_album: create(:bill_album, telegram_chat: chat))

    expect(described_class.call(bill_image: bill_image)).to be_empty
    expect(bill_image.reload.metadata["skipped_child_receipts"]).to eq([ 0 ])
  end

  it "builds a transfer as the reviewed total transaction in an album" do
    bill_image = analyzed_bill(extraction: "transfer")
    bill_image.update!(bill_album: create(:bill_album, telegram_chat: chat))

    transaction = described_class.call(bill_image: bill_image).sole
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("album_total_review")
  end

  it "sends a complete album settlement to review when the agent cannot be told" do
    document = extraction_fixture("normal_settlement")["documents"].first.merge("merchant_name" => "HỘ KINH DOANH THIÊN KIM GV")
    normalized = BillVision::Normalizer.call({ "documents" => [ document ] }, provider: "openai", model: "gpt-test")
    bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                     bill_album: create(:bill_album, telegram_chat: chat),
                                     normalized_extraction: normalized, ocr_status: "completed")

    transaction = described_class.call(bill_image: bill_image).sole
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("dealer_unmapped")
    expect(transaction.review_reason_codes).not_to include("album_total_review")
  end

  it "judges a complete settlement in an album like a single photo (child bills dropped)" do
    bill_image = analyzed_bill(extraction: "normal_settlement")
    bill_image.update!(bill_album: create(:bill_album, telegram_chat: chat))

    transaction = described_class.call(bill_image: bill_image).sole
    expect(transaction.review_reason_codes).not_to include("album_total_review")
  end

  it "keeps an incomplete settlement in an album as a reviewed total transaction" do
    document = extraction_fixture("normal_settlement")["documents"].first.merge("lot_number" => nil)
    normalized = BillVision::Normalizer.call({ "documents" => [ document ] }, provider: "openai", model: "gpt-test")
    bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                     bill_album: create(:bill_album, telegram_chat: chat),
                                     normalized_extraction: normalized, ocr_status: "needs_review")

    transaction = described_class.call(bill_image: bill_image).sole
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("album_total_review")
  end

  it "knows when a settlement printed everything" do
    document = normalized_document
    expect(described_class.complete_settlement?(document)).to be(true)
    %w[lot_number transaction_time transaction_date total_amount_vnd merchant_name terminal_or_merchant_id].each do |field|
      expect(described_class.complete_settlement?(document.merge(field => nil))).to be(false)
    end
    # The agent suffix is optional: a name cut short by the POS screen still counts.
    expect(described_class.complete_settlement?(document.merge("merchant_name" => "001_ HỘ KINH DOANH THIÊN KIM..."))).to be(true)
    expect(described_class.complete_settlement?(document.merge("document_type" => "transfer"))).to be(false)
  end

  it "skips unreadable (unknown) documents in an album" do
    normalized = BillVision::Normalizer.call({ "documents" => [] }, provider: "openai", model: "gpt-test")
    bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                     normalized_extraction: normalized, ocr_status: "needs_review",
                                     bill_album: create(:bill_album, telegram_chat: chat))

    expect(described_class.call(bill_image: bill_image)).to be_empty
  end

  it "skips a settlement with an unreadable amount in an album" do
    normalized = BillVision::Normalizer.call(
      { "documents" => [ { "document_type" => "settlement", "total_amount_vnd" => nil,
                           "transaction_date" => "2026-10-04", "transaction_time" => "12:00:00",
                           "merchant_name" => "HỘ KINH DOANH THIÊN KIM GV" } ] },
      provider: "openai", model: "gpt-test"
    )
    bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                     normalized_extraction: normalized, ocr_status: "needs_review",
                                     bill_album: create(:bill_album, telegram_chat: chat))

    expect(described_class.call(bill_image: bill_image)).to be_empty
  end

  it "inherits merchant, lot and time from child receipts in the same album" do
    album = create(:bill_album, telegram_chat: chat)

    child = { "document_type" => "child_receipt", "total_amount_vnd" => 100_000_000,
              "transaction_date" => "2026-10-04", "transaction_time" => "18:33:32",
              "merchant_name" => "HỘ KINH DOANH THIÊN KIM GV", "lot_number" => "000078",
              "confidence" => BillVision::Prompt::FIELDS.index_with { 0.97 } }
    child_norm = BillVision::Normalizer.call({ "documents" => [ child ] }, provider: "openai", model: "gpt-test")
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        normalized_extraction: child_norm, ocr_status: "completed")

    settlement = { "document_type" => "settlement", "total_amount_vnd" => 100_000_000,
                   "transaction_date" => "2026-10-04", "transaction_time" => nil,
                   "merchant_name" => nil, "lot_number" => nil,
                   "confidence" => BillVision::Prompt::FIELDS.index_with { 0.97 }.merge(
                     "merchant_name" => 0.0, "transaction_time" => 0.0, "lot_number" => 0.0
                   ) }
    settlement_norm = BillVision::Normalizer.call({ "documents" => [ settlement ] },
                                                  provider: "openai", model: "gpt-test")
    settlement_image = create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                                           normalized_extraction: settlement_norm, ocr_status: "needs_review")

    transaction = described_class.call(bill_image: settlement_image).sole

    expect(transaction).to be_needs_review
    expect(transaction.lot_number).to eq("000078")
    expect(transaction.transaction_at).to eq(Time.zone.local(2026, 10, 4, 18, 33, 32))
    expect(transaction.review_reason_codes).to include("album_total_review")
    expect(transaction.review_reason_codes).not_to include("transaction_time_missing", "transaction_time_unreadable")

    extraction = transaction.source_data["extraction"]
    expect(extraction["critical_confidence"]).to be > 0.9
    expect(extraction["low_confidence_fields"]).not_to include("transaction_time")
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
    expect(transaction.dealer).to be_nil
    expect(transaction.review_reason_codes).to eq([ "ocr_failed" ])
  end

  it "enqueues the workbook job for an auto-approved transaction" do
    expect { @transaction = described_class.call(bill_image: analyzed_bill).sole }
      .to have_enqueued_job(WriteHelloSmcWorkbookJob)
    expect(@transaction).to be_approved
  end

  it "does not enqueue the workbook job for a transaction that needs review" do
    expect { @transaction = described_class.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }
      .not_to have_enqueued_job(WriteHelloSmcWorkbookJob)
    expect(@transaction).to be_needs_review
  end

  it "does not enqueue the workbook job when OCR failed" do
    bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                     ocr_status: "failed", processing_error: "boom")
    expect { described_class.call(bill_image: bill_image) }
      .not_to have_enqueued_job(WriteHelloSmcWorkbookJob)
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

  let!(:tran3) { create(:merchant, name: "Trân 3", code: "TRAN3") }
  let!(:tran3_link) do
    create(:merchant_dealer, merchant: tran3, dealer: dealer, tid_key: "tid1",
           ds_sheet_anchor: "Trân 3", ds_header: "Trân (tid1)", rd_agent_label: "Trân")
  end

  def document(merchant_name:, amount:, time:, lot:)
    { "document_type" => "settlement", "total_amount_vnd" => amount, "lot_number" => lot,
      "transaction_date" => "2026-10-04", "transaction_time" => time, "merchant_name" => "#{merchant_name}-1",
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

  it "does not book an approved bill again when the rerun reads it a little differently" do
    second = bill_image.transactions.find_by!(source_index: 1)
    second.transition_to!("processing")
    analyze(bill_image, [ thien_kim_doc.merge("transaction_time" => "09:01:00"), tran3_doc ])
    described_class.call(bill_image: bill_image)

    expect(bill_image.transactions.count).to eq(2)
    expect(bill_image.transactions.find_by!(source_index: 0)).to be_approved
    expect(second.reload.merchant).to eq(tran3)
  end

  it "does not book an approved bill again when the rerun cannot read its time" do
    second = bill_image.transactions.find_by!(source_index: 1)
    second.transition_to!("processing")
    analyze(bill_image, [ thien_kim_doc.merge("transaction_time" => nil), tran3_doc ])
    described_class.call(bill_image: bill_image)

    expect(bill_image.transactions.count).to eq(2)
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

  describe "HKD and agent come from the bill, not the Telegram group" do
    it "approves whatever the group is called" do
      chat.update!(name: "Chị Lan-Cherry Coffee")
      create(:merchant_dealer, merchant: merchant, dealer: create(:dealer, name: "Chị Lan"), tid_key: "tid2")

      transaction = described_class.call(bill_image: analyzed_bill).sole

      expect(transaction).to be_approved
      expect(transaction.dealer).to eq(dealer)
    end

    it "never auto-approves an agent inferred only from the transfer recipient" do
      result = Dealers::Resolver::Result.new(dealer: dealer, merchant_dealer: merchant_dealer_link, source: "recipient", issue: nil)
      allow(Dealers::Resolver).to receive(:call).and_return(result)
      transaction = described_class.call(bill_image: analyzed_bill).sole
      expect(transaction).to be_needs_review
      expect(transaction.review_reason_codes).to include("dealer_from_recipient")
    end
  end
end
