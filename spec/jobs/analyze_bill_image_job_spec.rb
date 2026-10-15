require "rails_helper"

RSpec.describe AnalyzeBillImageJob do
  let(:bill_image) { create(:bill_image) }

  it "stores raw and normalized extraction, then enqueues the builder" do
    stub_vision(extraction_fixture("normal_settlement"))

    described_class.perform_now(bill_image.id)

    bill_image.reload
    expect(bill_image).to be_ocr_completed
    expect(bill_image.ocr_attempts).to eq(1)
    expect(bill_image.raw_extraction["fixture"]).to be(true)
    expect(bill_image.documents.first["total_amount_vnd"]).to eq(11_445_000)
    expect(bill_image.ocr_confidence).to eq(BigDecimal("0.95"))
    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
  end

  it "marks low-confidence results as needs_review" do
    stub_vision(extraction_fixture("blurry_settlement"))
    described_class.perform_now(bill_image.id)
    expect(bill_image.reload).to be_ocr_needs_review
  end

  it "routes conflicting transfer evidence to transfer review even for an unregistered sender" do
    message = create(:telegram_message)
    image = create(:bill_image, telegram_message: message)
    data = extraction_fixture("transfer")
    data["documents"].first.merge!("shows_success_message" => true, "shows_qr_code" => true)
    stub_vision(data)

    described_class.perform_now(image.id)

    transfer = message.reload.remitter_transfer
    expect(transfer).to be_present
    expect(BuildRemitterTransferJob).to have_been_enqueued.with(transfer.id)
    expect(BuildTransactionJob).not_to have_been_enqueued
    BuildRemitterTransferJob.perform_now(transfer.id)
    expect(transfer.reload).to be_needs_review
    expect(transfer.review_reasons).to include("transfer_confirmation_conflict", "remitter_unknown")
    expect(WriteRemitterReportJob).not_to have_been_enqueued
  end

  it "does not call the provider twice for an analyzed image" do
    stub_vision(extraction_fixture("normal_settlement"))
    described_class.perform_now(bill_image.id)
    described_class.perform_now(bill_image.id)
    expect(BillVision::Extractor).to have_received(:call).once
  end

  it "re-runs when forced" do
    stub_vision(extraction_fixture("normal_settlement"))
    described_class.perform_now(bill_image.id)
    described_class.perform_now(bill_image.id, force: true)
    expect(BillVision::Extractor).to have_received(:call).twice
  end

  it "marks permanent provider failures as failed and still builds a placeholder" do
    allow(BillVision::Extractor).to receive(:call).and_raise(BillVision::PermanentError, "invalid key")
    described_class.perform_now(bill_image.id)

    expect(bill_image.reload).to be_ocr_failed
    expect(bill_image.processing_error).to eq("invalid key")
    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
  end

  it "retries transient failures" do
    allow(BillVision::Extractor).to receive(:call).and_raise(BillVision::TransientError, "timeout")
    described_class.perform_now(bill_image.id)

    expect(bill_image.reload.processing_error).to eq("timeout")
    expect(described_class).to have_been_enqueued.with(bill_image.id)
  end

  it "skips duplicates" do
    duplicate = create(:bill_image, duplicate_of: bill_image, ocr_status: "duplicate")
    stub_vision(extraction_fixture("normal_settlement"))
    described_class.perform_now(duplicate.id)
    expect(BillVision::Extractor).not_to have_received(:call)
  end

  it "routes album images to the album finalizer instead of the builder" do
    album = create(:bill_album)
    bill_image.update!(bill_album: album)
    stub_vision(extraction_fixture("normal_settlement"))

    described_class.perform_now(bill_image.id)

    expect(FinalizeBillAlbumJob).to have_been_enqueued.with(album.id)
    expect(BuildTransactionJob).not_to have_been_enqueued
  end

  it "re-opens a finished album on a forced re-run so it re-reconciles" do
    album = create(:bill_album, status: "reconciled", reconciliation_status: "matched")
    bill_image.update!(bill_album: album)
    stub_vision(extraction_fixture("normal_settlement"))

    described_class.perform_now(bill_image.id, force: true)

    expect(album.reload.status).to eq("processing")
    expect(album.reconciliation_status).to be_nil
    expect(FinalizeBillAlbumJob).to have_been_enqueued.with(album.id)
  end

  it "re-opens the album even when a forced re-run fails" do
    album = create(:bill_album, status: "reconciled", reconciliation_status: "matched")
    bill_image.update!(bill_album: album)
    allow(BillVision::Extractor).to receive(:call).and_raise(BillVision::PermanentError, "invalid key")

    described_class.perform_now(bill_image.id, force: true)

    expect(album.reload.status).to eq("processing")
    expect(album.reconciliation_status).to be_nil
  end
end

RSpec.describe BillImages::Analyzer do
  let(:bill_image) { create(:bill_image) }

  it "turns unexpected errors into retryable failures instead of leaving the bill stuck" do
    allow(BillVision::Extractor).to receive(:call).and_raise(Faraday::SSLError, "handshake")
    expect { described_class.call(bill_image, job_id: "job-1") }.to raise_error(BillVision::TransientError, /SSLError/)
    expect(bill_image.reload.processing_error).to include("SSLError")
  end

  it "counts a transient network retry as a new run so it consumes the lifetime budget" do
    allow(BillVision::Extractor).to receive(:call).and_raise(BillVision::TransientError, "timeout")
    2.times { expect { described_class.call(bill_image, job_id: "job-1") }.to raise_error(BillVision::TransientError) }
    expect(bill_image.reload.ocr_attempts).to eq(2)
  end

  it "skips an image another job is analyzing right now" do
    bill_image.update!(ocr_status: "processing", metadata: { "ocr_claim" => "job-other" })
    stub_vision(extraction_fixture("normal_settlement"))
    expect(described_class.call(bill_image, job_id: "job-1").status).to eq(:in_progress)
    expect(BillVision::Extractor).not_to have_received(:call)
  end

  it "skips a concurrent duplicate delivery of the same job" do
    bill_image.update!(ocr_status: "processing", metadata: { "ocr_claim" => "job-1" })
    stub_vision(extraction_fixture("normal_settlement"))
    expect(described_class.call(bill_image, force: true, job_id: "job-1").status).to eq(:in_progress)
    expect(BillVision::Extractor).not_to have_received(:call)
  end

  it "ignores a late permanent failure from a worker that lost ownership" do
    allow(BillVision::Extractor).to receive(:call) do
      bill_image.update!(ocr_status: "processing", metadata: bill_image.metadata.merge(
        "vision_pipeline" => { "run_id" => "new-run", "calls" => { "primary" => 0, "validator" => 0 } }
      ))
      raise BillVision::PermanentError, "old failure"
    end
    expect(described_class.call(bill_image, job_id: "old-job").status).to eq(:in_progress)
    expect(bill_image.reload).to be_ocr_processing
    expect(bill_image.processing_error).to be_nil
    expect(bill_image.metadata.dig("vision_pipeline", "run_id")).to eq("new-run")
  end

  it "does not let an exhausted old retry callback overwrite another job's run" do
    bill_image.update!(ocr_status: "processing", metadata: { "ocr_claim" => "new-job" })
    expect(described_class.mark_failed!(bill_image, BillVision::TransientError.new("old timeout"), job_id: "old-job")).to be(false)
    expect(bill_image.reload).to be_ocr_processing
  end
end

RSpec.describe RetryFailedExtractionJob do
  it "marks abandoned runs failed so they surface for a human" do
    bill_image = create(:bill_image, ocr_status: "processing")
    bill_image.update_columns(updated_at: 2.hours.ago)

    described_class.perform_now
    expect(bill_image.reload).to be_ocr_failed
    expect(BuildTransactionJob).to have_been_enqueued.with(bill_image.id)
  end

  it "routes an abandoned transfer candidate to failed outgoing review instead of incoming transactions" do
    allow(AppConfig).to receive(:remitter_features_enabled?).and_return(true)
    message = create(:telegram_message, raw_payload: { "remitter_transfer_candidate" => true })
    image = create(:bill_image, telegram_message: message, ocr_status: "processing", ocr_attempts: AppConfig.max_ocr_attempts)
    image.update_columns(updated_at: 2.hours.ago)

    described_class.perform_now

    expect(RemitterTransfer.sole.telegram_message).to eq(message)
    expect(BuildRemitterTransferJob).to have_been_enqueued.with(RemitterTransfer.sole.id)
    expect(BuildTransactionJob).not_to have_been_enqueued
  end

  it "retries failed images that have runs left" do
    bill_image = create(:bill_image, ocr_status: "failed", ocr_attempts: 1)
    described_class.perform_now
    expect(AnalyzeBillImageJob).to have_been_enqueued.with(bill_image.id, force: true)
  end
end
