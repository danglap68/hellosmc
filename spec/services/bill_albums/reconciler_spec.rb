require "rails_helper"

RSpec.describe BillAlbums::Reconciler do
  include_context "accounting setup"

  let(:album) { create(:bill_album, telegram_chat: chat) }

  def raw_document(type, amount, merchant: "HỘ KINH DOANH THIÊN KIM GV")
    {
      "document_type" => type,
      "total_amount_vnd" => amount,
      "lot_number" => nil,
      "transaction_date" => "2026-10-04",
      "transaction_time" => "12:00:00",
      "merchant_name" => (type == "transfer" ? nil : merchant),
      "terminal_or_merchant_id" => nil,
      "confidence" => BillVision::Prompt::FIELDS.index_with { 0.97 }.merge(
        "merchant_name" => (type == "transfer" ? 0.0 : 0.97), "terminal_or_merchant_id" => 0.0
      )
    }
  end

  def analyzed_image(document, ocr_status: nil)
    normalized = BillVision::Normalizer.call({ "documents" => [ document ] }, provider: "openai", model: "gpt-test")
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        normalized_extraction: normalized,
                        ocr_status: ocr_status || (normalized["requires_review"] ? "needs_review" : "completed"))
  end

  def reconcile
    described_class.call(album)
    album.reload
  end

  def child_bill(amount, merchant: "HỘ KINH DOANH THIÊN KIM GV")
    analyzed_image(raw_document("child_receipt", amount, merchant: merchant))
  end

  def transfer(amount)
    analyzed_image(raw_document("transfer", amount))
  end

  it "matches the example: three child bills and a matching transfer" do
    child_bill(100_000_000)
    child_bill(200_000_000)
    child_bill(300_000_000)
    transfer(600_000_000)

    reconcile

    expect(album.status).to eq("reconciled")
    expect(album.reconciliation_status).to eq("matched")
    expect(album.child_total_vnd).to eq(600_000_000)
    expect(album.child_count).to eq(3)
    expect(album.transfer_count).to eq(1)
    expect(album.transfer_amount_vnd).to eq(600_000_000)
    expect(album.match_difference_vnd).to be_nil
    expect(album.transfer_bill_image).to be_present
    expect(album.transactions.count).to eq(1)
    expect(album.transactions.sole).to be_needs_review
    expect(album.transactions.sole.review_reason_codes).to include("album_total_review")
  end

  it "drops the child bills when the settlement printed everything" do
    child_bill(100_000_000)
    child_bill(50_000_000)
    analyzed_image(raw_document("settlement", 600_000_000).merge("lot_number" => "000269", "terminal_or_merchant_id" => "000000123456"))

    reconcile

    expect(album.status).to eq("reconciled")
    expect(album.reconciliation_status).to eq("settlement_complete")
    expect(album.metadata["children_dropped"]).to be(true)
    expect(album.transactions.sole.review_reason_codes).not_to include("album_total_review", "album_total_mismatch")
  end

  it "skips a child whose OCR failed when the settlement is complete" do
    child_bill(100_000_000)
    failed = create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                                 ocr_status: "failed", processing_error: "boom")
    analyzed_image(raw_document("settlement", 600_000_000).merge("lot_number" => "000269", "terminal_or_merchant_id" => "000000123456"))

    reconcile

    expect(album.reconciliation_status).to eq("settlement_complete")
    expect(album.metadata["skipped_failed_image_ids"]).to eq([ failed.id ])
    expect(failed.transactions.count).to eq(0)
    expect(album.transactions.pluck(:status)).not_to include("failed")
  end

  it "still reviews a failed photo when the settlement is incomplete" do
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        ocr_status: "failed", processing_error: "boom")
    analyzed_image(raw_document("settlement", 600_000_000))

    reconcile

    expect(album.reconciliation_status).to eq("incomplete")
  end

  it "forgets what an earlier run recorded when a re-run no longer finds the settlement complete" do
    child_bill(600_000_000)
    settlement = analyzed_image(raw_document("settlement", 600_000_000).merge("lot_number" => "000269", "terminal_or_merchant_id" => "000000123456"))
    reconcile
    expect(album.metadata["children_dropped"]).to be(true)

    album.update!(status: "processing", reconciliation_status: nil)
    incomplete = BillVision::Normalizer.call({ "documents" => [ raw_document("settlement", 600_000_000) ] }, provider: "openai", model: "gpt-test")
    settlement.update!(normalized_extraction: incomplete)
    reconcile

    expect(album.reconciliation_status).to eq("matched")
    expect(album.metadata).not_to include("children_dropped")
  end

  it "keeps the child bills to fill in a settlement that is missing fields" do
    child_bill(600_000_000)
    analyzed_image(raw_document("settlement", 600_000_000))

    reconcile

    expect(album.reconciliation_status).to eq("matched")
    expect(album.metadata["children_dropped"]).to be_nil
    expect(album.transactions.sole.review_reason_codes).to include("album_total_review")
  end

  it "flags a mismatch and records the difference" do
    child_bill(100_000_000)
    child_bill(200_000_000)
    child_bill(200_000_000)
    transfer(600_000_000)

    reconcile

    expect(album.status).to eq("needs_review")
    expect(album.reconciliation_status).to eq("mismatched")
    expect(album.match_difference_vnd).to eq(-100_000_000)
    expect(album.transactions.count).to eq(1)
    expect(album.transactions.sole.review_reason_codes).to include("album_total_mismatch")
  end

  it "sums child bills across multiple images" do
    analyzed_image(raw_document("child_receipt", 100_000_000, merchant: "HỘ KINH DOANH THIÊN KIM GV"))
    # two bills in one image
    image = analyzed_image(raw_document("child_receipt", 200_000_000))
    normalized = BillVision::Normalizer.call(
      { "documents" => [ raw_document("child_receipt", 200_000_000), raw_document("child_receipt", 300_000_000) ] },
      provider: "openai", model: "gpt-test"
    )
    image.update!(normalized_extraction: normalized, ocr_status: "completed")
    transfer(600_000_000)

    reconcile

    expect(album.child_total_vnd).to eq(600_000_000)
    expect(album.child_count).to eq(3)
    expect(album.reconciliation_status).to eq("matched")
  end

  it "skips the album when there is no transfer" do
    child_bill(100_000_000)
    child_bill(200_000_000)

    reconcile

    expect(album.status).to eq("skipped")
    expect(album.reconciliation_status).to eq("no_transfer")
    expect(album.child_total_vnd).to eq(300_000_000)
    expect(album.transactions).to be_empty
  end

  it "skips with transfer_duplicate when the transfer image is a duplicate" do
    child_bill(100_000_000)
    original = analyzed_image(raw_document("transfer", 100_000_000))
    original.update!(bill_album: nil)
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        duplicate_of: original, ocr_status: "duplicate")

    reconcile

    expect(album.status).to eq("skipped")
    expect(album.reconciliation_status).to eq("transfer_duplicate")
    expect(album.metadata["skip_reason"]).to eq("transfer_duplicate")
  end

  it "does not treat a duplicate of a non-transfer image as transfer_duplicate" do
    child_bill(100_000_000)
    original = child_bill(200_000_000)
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        duplicate_of: original, ocr_status: "duplicate")

    reconcile

    expect(album.reconciliation_status).to eq("no_transfer")
  end

  it "flags multiple transfers" do
    child_bill(600_000_000)
    transfer(300_000_000)
    transfer(300_000_000)

    reconcile

    expect(album.status).to eq("needs_review")
    expect(album.reconciliation_status).to eq("multiple_transfers")
    expect(album.metadata["total_amounts"]).to eq([ 300_000_000, 300_000_000 ])
  end

  it "flags a transfer without child bills" do
    transfer(600_000_000)

    reconcile

    expect(album.status).to eq("needs_review")
    expect(album.reconciliation_status).to eq("missing_bills")
    expect(album.transactions.count).to eq(1)
    expect(album.transactions.sole.review_reason_codes).to include("album_missing_bills")
  end

  it "flags an unreadable child amount" do
    analyzed_image(raw_document("child_receipt", nil))
    transfer(100_000_000)

    reconcile

    expect(album.status).to eq("needs_review")
    expect(album.reconciliation_status).to eq("incomplete")
    expect(album.transactions.sole.review_reason_codes).to include("album_amount_unreadable")
  end

  it "flags an album with a failed image and still books healthy bills" do
    child_bill(100_000_000)
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        ocr_status: "failed", processing_error: "boom")
    transfer(600_000_000)

    reconcile

    expect(album.status).to eq("needs_review")
    expect(album.reconciliation_status).to eq("incomplete")
    expect(album.transactions.map(&:review_reason_codes).flatten).to include("album_ocr_failed")
  end

  it "accepts a settlement as the total source (dynamic total)" do
    child_bill(100_000_000)
    child_bill(200_000_000)
    child_bill(300_000_000)
    analyzed_image(raw_document("settlement", 600_000_000))

    reconcile

    expect(album.child_count).to eq(3)
    expect(album.child_total_vnd).to eq(600_000_000)
    expect(album.transfer_count).to eq(1)
    expect(album.transfer_amount_vnd).to eq(600_000_000)
    expect(album.reconciliation_status).to eq("matched")
    expect(album.transactions.count).to eq(1)
  end

  it "treats both a settlement and a transfer as multiple totals" do
    child_bill(600_000_000)
    analyzed_image(raw_document("settlement", 600_000_000))
    transfer(600_000_000)

    reconcile

    expect(album.reconciliation_status).to eq("multiple_transfers")
    expect(album.metadata["total_amounts"]).to eq([ 600_000_000, 600_000_000 ])
  end

  it "ignores a settlement with an unreadable amount (confirm popup)" do
    child_bill(100_000_000)
    child_bill(200_000_000)
    child_bill(300_000_000)
    analyzed_image(raw_document("settlement", 600_000_000))
    analyzed_image(raw_document("settlement", nil))

    reconcile

    expect(album.child_count).to eq(3)
    expect(album.transfer_count).to eq(1)
    expect(album.transfer_amount_vnd).to eq(600_000_000)
    expect(album.reconciliation_status).to eq("matched")
    expect(album.transactions.count).to eq(1)
  end

  it "does not re-reconcile an already-terminal album" do
    child_bill(100_000_000)
    child_bill(200_000_000)
    child_bill(300_000_000)
    transfer(600_000_000)

    described_class.call(album)
    described_class.call(album)

    expect(album.reload.transactions.count).to eq(1)
    expect(album.reload.status).to eq("reconciled")
    expect(AuditLog.where(action: "bill_album.reconciled", auditable: album).count).to eq(1)
  end
end
