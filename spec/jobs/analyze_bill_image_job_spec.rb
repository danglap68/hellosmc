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
end

RSpec.describe BillImages::Analyzer do
  let(:bill_image) { create(:bill_image) }

  it "turns unexpected errors into retryable failures instead of leaving the bill stuck" do
    allow(BillVision::Extractor).to receive(:call).and_raise(Faraday::SSLError, "handshake")
    expect { described_class.call(bill_image, job_id: "job-1") }.to raise_error(BillVision::TransientError, /SSLError/)
    expect(bill_image.reload.processing_error).to include("SSLError")
  end

  it "counts one attempt per run, not per retry" do
    allow(BillVision::Extractor).to receive(:call).and_raise(BillVision::TransientError, "timeout")
    2.times { expect { described_class.call(bill_image, job_id: "job-1") }.to raise_error(BillVision::TransientError) }
    expect(bill_image.reload.ocr_attempts).to eq(1)
  end

  it "skips an image another job is analyzing right now" do
    bill_image.update!(ocr_status: "processing", metadata: { "ocr_claim" => "job-other" })
    stub_vision(extraction_fixture("normal_settlement"))
    expect(described_class.call(bill_image, job_id: "job-1").status).to eq(:in_progress)
    expect(BillVision::Extractor).not_to have_received(:call)
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

  it "retries failed images that have runs left" do
    bill_image = create(:bill_image, ocr_status: "failed", ocr_attempts: 1)
    described_class.perform_now
    expect(AnalyzeBillImageJob).to have_been_enqueued.with(bill_image.id, force: true)
  end
end
