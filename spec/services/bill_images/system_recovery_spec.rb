require "rails_helper"

RSpec.describe BillImages::SystemRecovery do
  include_context "accounting setup"

  let(:image) { analyzed_bill }
  let!(:row) do
    Transactions::Builder.call(bill_image: image).sole.tap do |transaction|
      transaction.transition_to!("hold")
      transaction.transition_to!("needs_review")
      transaction.update!(source_data: transaction.source_data.merge("review_reasons" => [ "model_disagreement" ]))
      image.update!(ocr_status: "needs_review", ocr_attempts: 1, metadata: {
        "vision_pipeline" => { "run_id" => "old-run", "review_reasons" => [ "model_disagreement" ] }
      })
    end
  end

  it "claims all affected rows atomically, audits the cause and enqueues exactly one bounded reread" do
    clear_enqueued_jobs
    expect(described_class.call(image)).to eq(:ocr)
    expect(row.reload).to be_processing
    expect(AnalyzeBillImageJob).to have_been_enqueued.with(image.id, force: true).once
    expect(row.audit_logs.last.metadata).to include("trigger" => "system_recovery", "mode" => "ocr")
    expect(described_class.call(image)).to eq(:skipped)
    expect(AnalyzeBillImageJob).to have_been_enqueued.once
  end

  it "does not touch held, human-corrected or booked images or exceed the lifetime budget" do
    row.transition_to!("hold")
    expect(described_class.call(image)).to eq(:skipped)
    row.transition_to!("needs_review")
    image.update!(ocr_attempts: AppConfig.max_ocr_attempts)
    expect(described_class.call(image)).to eq(:budget_exhausted)
    image.update!(ocr_attempts: 1)
    AuditLogger.log!(actor: create(:user), action: "transaction.corrected", auditable: row)
    expect(described_class.call(image)).to eq(:skipped)
    expect(row.reload).to be_needs_review
  end

  it "ignores an old delayed recovery job after a newer run finished" do
    expect(described_class.call(image, expected_run_id: "older-run")).to eq(:stale)
    expect(row.reload).to be_needs_review
  end

  it "preserves every row when a sibling was deliberately held or already booked" do
    sibling = create(:transaction, :hold, bill_image: image)
    expect(described_class.call(image)).to eq(:skipped)
    expect(row.reload).to be_needs_review
    sibling.destroy!
    WorkbookEntry.create!(recorded_transaction: row, spreadsheet_id: "sheet", branch: "identified",
                          ds_sheet: "DS", ds_cell: "D4", amount_vnd: row.transaction_amount_vnd)
    expect(described_class.call(image)).to eq(:skipped)
    expect(row.reload).to be_needs_review
  end

  it "rebuilds a resolved catalog conflict from stored facts without consuming OCR runs" do
    row.update!(source_data: row.source_data.merge("review_reasons" => [ "merchant_ai_conflict" ]))
    image.update!(ocr_attempts: AppConfig.max_ocr_attempts)
    clear_enqueued_jobs
    expect(described_class.call(image)).to eq(:rebuild)
    expect(BuildTransactionJob).to have_been_enqueued.with(image.id)
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    BuildTransactionJob.perform_now(image.id)
    expect(row.reload).to be_approved
    expect(image.reload.ocr_attempts).to eq(AppConfig.max_ocr_attempts)
  end

  it "does not reread a duplicate or a real missing business configuration" do
    row.update!(source_data: row.source_data.merge("review_reasons" => [ "possible_duplicate" ]))
    expect(described_class.call(image)).to eq(:skipped)
    row.update!(source_data: row.source_data.merge("review_reasons" => [ "dealer_unmapped" ]))
    expect(described_class.call(image)).to eq(:skipped)
  end
end
