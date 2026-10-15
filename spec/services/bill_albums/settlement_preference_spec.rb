require "rails_helper"

RSpec.describe BillAlbums::SettlementPreference do
  include_context "accounting setup"

  let(:album) { create(:bill_album, telegram_chat: chat) }
  let(:receipt) { extraction_fixture("normal_settlement")["documents"].first }

  def image(documents)
    normalized = BillVision::Normalizer.call({ "documents" => documents }, provider: "openai", model: "fixture")
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
      normalized_extraction: normalized, ocr_status: normalized["requires_review"] ? "needs_review" : "completed")
  end

  def mixed_photo(amount: 11_400_000, amount_confidence: 0.96, **changes)
    image([ receipt.merge("total_amount_vnd" => amount, "lot_number" => nil,
                         "confidence" => receipt["confidence"].merge("total_amount_vnd" => amount_confidence), **changes),
           receipt.merge("document_type" => "child_receipt", "total_amount_vnd" => 5_000_000),
           receipt.merge("document_type" => "child_receipt", "total_amount_vnd" => 6_445_000) ])
  end

  def reconcile
    album.update!(status: "processing", reconciliation_status: nil)
    BillAlbums::Reconciler.call(album)
    album.reload
  end

  it "uses the standalone settlement even when OCR misread the total on the group photo" do
    mixed = mixed_photo
    single = image([ receipt ])
    expect(Transactions::Builder.call(bill_image: mixed)).to be_empty
    clear_enqueued_jobs

    reconcile

    expect(album).to have_attributes(transfer_count: 1, transfer_bill_image_id: single.id,
      transfer_amount_vnd: 11_445_000, reconciliation_status: "settlement_complete")
    expect(album.transactions.sole).to have_attributes(bill_image_id: single.id, transaction_amount_vnd: 11_445_000, status: "approved")
    expect(album.metadata["preferred_settlements"]).to eq([ { "image_id" => single.id, "source_index" => 0,
      "secondary_image_id" => mixed.id, "secondary_source_index" => 0 } ])
    expect(WriteHelloSmcWorkbookJob).to have_been_enqueued.once
  end

  it "keeps other settlements on the mixed photo and separate standalone settlements" do
    mixed = image([ receipt, receipt.merge("total_amount_vnd" => 7_000_000, "transaction_time" => "09:00:00", "lot_number" => "000300") ])
    single = image([ receipt ])
    other = image([ receipt.merge("total_amount_vnd" => 8_000_000, "transaction_time" => "08:00:00", "lot_number" => "000301") ])
    reconcile
    expect(album.transfer_count).to eq(3)
    expect(album.transactions.map { |row| [ row.bill_image_id, row.transaction_amount_vnd ] })
      .to contain_exactly([ single.id, 11_445_000 ], [ mixed.id, 7_000_000 ], [ other.id, 8_000_000 ])
  end

  it "does not suppress a distinct batch or choose between two possible standalone sources" do
    mixed = mixed_photo
    image([ receipt.merge("transaction_time" => "09:00:00") ])
    expect(described_class.call(album).pairs).to be_empty
    image([ receipt ])
    image([ receipt.merge("total_amount_vnd" => 12_000_000) ])
    expect(described_class.call(album).pairs).to be_empty
    expect(described_class.call(album).suppressed?(mixed, mixed.documents.first)).to be(false)
  end

  it "does not prefer an unreadable amount just because the photo contains one receipt" do
    mixed_photo
    blurry = receipt.deep_dup
    blurry["confidence"]["total_amount_vnd"] = 0.4
    image([ blurry ])
    expect(described_class.call(album).pairs).to be_empty
  end

  it "retires an old unbooked group-photo record and rebuilds its standalone replacement without OCR" do
    mixed = mixed_photo(amount: 11_445_000, amount_confidence: 0.4)
    old = Transactions::Builder.call(bill_image: mixed).sole
    single = image([ receipt ])
    replacement = Transactions::Builder.call(bill_image: single).sole
    clear_enqueued_jobs
    reconcile
    expect(old.reload).to be_excluded
    expect(replacement.reload).to be_approved
    expect(old.source_data["canonical_transaction_id"]).to eq(replacement.id)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    expect(WriteHelloSmcWorkbookJob).to have_been_enqueued.once
  end

  it "does not create a second row when an approved group-photo record can use the separate photo as evidence" do
    mixed = mixed_photo
    single = image([ receipt ])
    canonical = posted_row(mixed, single)
    clear_enqueued_jobs
    reconcile
    expect(album.transactions.sole).to eq(canonical)
    expect(canonical.reload.evidence_bill_image).to eq(single)
    expect(WriteHelloSmcWorkbookJob).not_to have_been_enqueued
  end

  def posted_row(mixed, single, amount: 11_445_000)
    evaluation = Transactions::Evaluator.call(document: single.documents.first, bill_image: single)
    row = create(:transaction, :approved, **evaluation.attributes, bill_image: mixed, source_index: 0,
      transaction_amount_vnd: amount, source_data: evaluation.source_data.merge("extraction" => mixed.documents.first))
    WorkbookEntry.create!(recorded_transaction: row, spreadsheet_id: "sheet", branch: "identified",
      ds_sheet: "DS", ds_cell: "D4", amount_vnd: amount)
    row
  end

  it "preserves posted accounting and its source while preferring the separate photo and retiring its duplicate row" do
    mixed = mixed_photo
    single = image([ receipt ])
    canonical = posted_row(mixed, single)
    evaluation = Transactions::Evaluator.call(document: single.documents.first, bill_image: single)
    duplicate = create(:transaction, **evaluation.attributes, bill_image: single, source_index: 0,
      source_data: evaluation.source_data.merge("review_reasons" => [ "possible_duplicate" ]))
    before = canonical.audit_snapshot
    ledger = canonical.workbook_entry.attributes
    clear_enqueued_jobs

    reconcile

    expect(canonical.reload.audit_snapshot).to eq(before)
    expect(canonical.workbook_entry.attributes).to eq(ledger)
    expect(canonical.bill_image).to eq(mixed)
    expect(canonical.evidence_bill_image).to eq(single)
    expect(duplicate.reload).to be_excluded
    expect(duplicate.source_data["canonical_transaction_id"]).to eq(canonical.id)
    expect(canonical.audit_logs.where(action: "transaction.evidence_prioritized").count).to eq(1)
    reconcile
    expect(album.transactions.count).to eq(2)
    expect(canonical.audit_logs.where(action: "transaction.evidence_prioritized").count).to eq(1)
    expect(WriteHelloSmcWorkbookJob).not_to have_been_enqueued
  end

  it "does not replace posted amounts or book another record when the preferred source conflicts with the ledger" do
    mixed = mixed_photo
    single = image([ receipt ])
    canonical = posted_row(mixed, single, amount: 11_400_000)
    before = canonical.attributes
    clear_enqueued_jobs
    reconcile
    expect(album).to be_needs_review
    expect(album.metadata["settlement_preference_conflicts"]).to be_present
    expect(canonical.reload.attributes).to eq(before)
    expect(album.transactions.count).to eq(1)
    expect(WriteHelloSmcWorkbookJob).not_to have_been_enqueued
  end

  it "preserves intentional holds and multiple posted records instead of merging financial decisions" do
    mixed = mixed_photo
    single = image([ receipt ])
    held = create(:transaction, :hold, bill_image: mixed, source_index: 0,
      source_data: { "extraction" => mixed.documents.first })
    before = held.attributes
    reconcile
    expect(album).to be_needs_review
    expect(held.reload.attributes).to eq(before)
    held.destroy!
    first = posted_row(mixed, single)
    another = mixed_photo
    second = posted_row(another, single)
    before = [ first.audit_snapshot, second.audit_snapshot ]
    reconcile
    expect(album).to be_needs_review
    expect([ first.reload.audit_snapshot, second.reload.audit_snapshot ]).to eq(before)
    expect(album.transactions.count).to eq(2)
  end
end
