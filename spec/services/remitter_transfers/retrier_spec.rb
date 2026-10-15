require "rails_helper"

RSpec.describe RemitterTransfers::Retrier do
  let(:actor) { create(:user, :operator) }
  let(:remitter) { Remitter.find_by!(excel_key: "LẬP") }
  let(:message) { create(:telegram_message, message_text: "TK1", telegram_sender_id: 777) }
  let(:image) { create(:bill_image, :analyzed, extraction: "transfer", telegram_message: message) }
  let(:transfer) do
    create(:remitter_transfer, telegram_message: message, bill_image: image, remitter: remitter,
                              status: "needs_review", amount_vnd: 29_274_000, review_reasons: [ "code_missing" ])
  end

  before { Workbook::Seed.call }

  def retry_transfer(**options)
    described_class.call(transfer: transfer, actor: actor, **options)
  end

  it "re-evaluates codes from existing OCR without another paid image read and records the actor" do
    expect { expect(retry_transfer.step).to eq(:evaluate) }.to have_enqueued_job(BuildRemitterTransferJob).with(transfer.id)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    expect(transfer.reload).to be_processing
    expect(transfer.review_reasons).to be_empty
    audit = AuditLog.find_by!(auditable: transfer, action: "remitter_transfer.retry_requested")
    expect(audit.actor_user).to eq(actor)
    expect(audit.metadata["step"]).to eq("evaluate")
    expect(audit.before_data["review_reasons"]).to eq([ "code_missing" ])
    expect(audit.after_data["review_reasons"]).to eq([])
  end

  it "replaces cleared warnings with the current evaluation's reasons" do
    remitter.update!(active: false)
    perform_enqueued_jobs(only: BuildRemitterTransferJob) { expect(retry_transfer).to be_ok }
    expect(transfer.reload).to be_needs_review
    expect(transfer.review_reasons).to eq([ "remitter_inactive" ])
  end

  it "re-resolves a newly configured remitter and approves through the existing duplicate and code checks" do
    remitter.update!(telegram_user_id: 777)
    transfer.update!(remitter: nil)
    perform_enqueued_jobs(only: BuildRemitterTransferJob) { expect(retry_transfer).to be_ok }
    expect(transfer.reload).to be_approved
    expect(transfer.remitter).to eq(remitter)
    expect(transfer.transfer_code).to eq("TK01")
    expect(WriteRemitterReportJob).to have_been_enqueued.with(transfer.id)
  end

  it "retries a failed download after commit without creating a second transfer" do
    transfer.update!(bill_image: nil, status: "failed", review_reasons: [ "image_missing" ])
    image.image.purge
    image.destroy!
    message.update!(processing_status: "failed", raw_payload: message.raw_payload.merge("download_error" => "timeout"))
    expect { expect(retry_transfer.step).to eq(:download) }.to have_enqueued_job(DownloadTelegramAttachmentJob).with(message.id)
    expect(transfer.reload).to be_processing
    expect(message.reload).to be_processing_queued
    expect(message.raw_payload).not_to have_key("download_error")
    expect(RemitterTransfer.where(telegram_message: message).count).to eq(1)
  end

  it "retries failed OCR within the original lifetime budget" do
    image.update!(ocr_status: "failed", ocr_attempts: 1)
    transfer.update!(status: "failed", review_reasons: [ "ocr_failed" ])
    expect { expect(retry_transfer.step).to eq(:ocr) }.to have_enqueued_job(AnalyzeBillImageJob).with(image.id, force: true)
    expect(image.reload.ocr_attempts).to eq(1)
    expect(transfer.reload).to be_processing
  end

  it "rereads an old transfer once to extract a memo that the old OCR contract never requested" do
    message.update!(message_text: nil)
    extraction = image.normalized_extraction.deep_dup
    extraction["documents"].each { |doc| doc.delete("transfer_memo"); doc.delete("transfer_memo_confidence") }
    image.update!(normalized_extraction: extraction)
    expect { expect(retry_transfer.step).to eq(:ocr) }.to have_enqueued_job(AnalyzeBillImageJob).with(image.id, force: true)
  end

  it "does not keep rereading new null memos just because the caption has no code" do
    message.update!(message_text: nil)
    expect(retry_transfer.step).to eq(:evaluate)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "keeps the lifetime OCR budget for the legacy memo retry" do
    message.update!(message_text: nil)
    extraction = image.normalized_extraction.deep_dup
    extraction["documents"].each { |doc| doc.delete("transfer_memo") }
    image.update!(normalized_extraction: extraction, ocr_attempts: AppConfig.max_ocr_attempts)
    expect(retry_transfer.error).to eq(:retry_budget_exhausted)
    expect(enqueued_jobs).to be_empty
  end

  it "rereads an uncertain amount but refuses an exhausted image budget" do
    transfer.update!(review_reasons: [ "amount_low_confidence" ])
    image.update!(ocr_attempts: AppConfig.max_ocr_attempts)
    expect(retry_transfer.error).to eq(:retry_budget_exhausted)
    expect(transfer.reload).to be_needs_review
    expect(transfer.review_reasons).to eq([ "amount_low_confidence" ])
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "can still re-evaluate a code with no OCR runs left" do
    image.update!(ocr_attempts: AppConfig.max_ocr_attempts)
    expect(retry_transfer.step).to eq(:evaluate)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "rereads a conflicting confirmation within its existing OCR budget" do
    transfer.update!(review_reasons: [ "transfer_confirmation_conflict", "model_disagreement" ])
    expect { expect(retry_transfer.step).to eq(:ocr) }.to have_enqueued_job(AnalyzeBillImageJob).with(image.id, force: true)
    expect(image.reload.ocr_attempts).to eq(0)
  end

  it "only requeues the sheet write for an approved transfer, preserving the approval and lock version" do
    link = RemitterTransfers::Codes.merchant_dealer_for("TK01")
    transfer.update!(status: "approved", merchant_dealer: link, merchant: link.merchant, transfer_code: "TK01",
                     reviewed_by: actor, reviewed_at: Time.current, metadata: { "write_issue" => "rd_sheet_missing" })
    before = transfer.attributes
    expect { expect(retry_transfer.step).to eq(:write) }.to have_enqueued_job(WriteRemitterReportJob).with(transfer.id)
    expect(transfer.reload.attributes).to eq(before)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "does not reopen an already written transfer or a human rejection" do
    transfer.update!(status: "rejected", reviewed_by: actor, reviewed_at: Time.current)
    expect(retry_transfer.error).to eq(:not_retryable)
    transfer.update!(status: "approved", written_at: Time.current)
    expect(retry_transfer.error).to eq(:already_written)
    expect(enqueued_jobs).to be_empty
  end

  it "allows an automatic non-transfer rejection to be reread, but never reopens a settlement handoff" do
    transfer.update!(status: "rejected", review_reasons: [ "settlement_photo" ])
    expect(retry_transfer.error).to eq(:not_retryable)
    transfer.update!(review_reasons: [ "not_a_transfer" ])
    expect(retry_transfer.step).to eq(:ocr)
  end

  it "does not restart a currently claimed OCR run or a fresh processing transfer" do
    image.update!(ocr_status: "processing")
    expect(retry_transfer.error).to eq(:retry_in_progress)
    image.update!(ocr_status: "completed")
    transfer.update!(status: "processing")
    expect(retry_transfer.error).to eq(:retry_in_progress)
    expect(enqueued_jobs).to be_empty
  end

  it "recovers an abandoned processing transfer from its completed OCR" do
    transfer.update!(status: "processing")
    transfer.update_columns(updated_at: 1.hour.ago)
    expect(retry_transfer.step).to eq(:evaluate)
  end

  it "refuses repeat clicks and stale requests" do
    version = transfer.lock_version
    expect(retry_transfer(lock_version: version)).to be_ok
    expect(retry_transfer(lock_version: version).error).to eq(:stale)
    expect(retry_transfer.error).to eq(:retry_in_progress)
    expect(BuildRemitterTransferJob).to have_been_enqueued.once
  end

  it "does not rerun a shared duplicate's original OCR" do
    duplicate = create(:bill_image, telegram_message: message, duplicate_of: image, ocr_status: "duplicate")
    transfer.update!(bill_image: duplicate, review_reasons: [ "possible_duplicate" ])
    expect(retry_transfer.step).to eq(:evaluate)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "refuses to reread an original shared image when it is failed" do
    image.update!(ocr_status: "failed")
    duplicate = create(:bill_image, telegram_message: message, duplicate_of: image, ocr_status: "duplicate")
    transfer.update!(bill_image: duplicate)
    expect(retry_transfer.error).to eq(:retry_shared_image)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "does not queue jobs or keep processing status when the outer transaction rolls back" do
    transfer
    RemitterTransfer.transaction do
      expect(retry_transfer).to be_ok
      raise ActiveRecord::Rollback
    end
    expect(transfer.reload).to be_needs_review
    expect(transfer.review_reasons).to eq([ "code_missing" ])
    expect(BuildRemitterTransferJob).not_to have_been_enqueued
    expect(AuditLog.where(auditable: transfer, action: "remitter_transfer.retry_requested")).not_to exist
  end
end
