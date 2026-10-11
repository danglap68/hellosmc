class AnalyzeBillImageJob < ApplicationJob
  queue_as :ocr

  # Transient provider failures are retried; when retries run out the bill is
  # marked failed and still surfaces as a failed transaction for a human.
  retry_on BillVision::TransientError, wait: :polynomially_longer, attempts: 3 do |job, error|
    bill_image = BillImage.find_by(id: job.arguments.first)
    if bill_image && BillImages::Analyzer.mark_failed!(bill_image, error, job_id: job.job_id)
      job.build_or_finalize(bill_image)
    end
  end

  def perform(bill_image_id, force: false)
    bill_image = BillImage.find(bill_image_id)
    # A forced re-run re-opens a finished (terminal) album BEFORE analyzing, so
    # the finalizer reconciles even if the re-run ends in a failed or exhausted
    # transient attempt — otherwise the reprocessed row stays stuck in processing.
    reopen_album(bill_image) if force && bill_image.bill_album_id
    result = BillImages::Analyzer.call(bill_image, force: force, job_id: job_id)
    build_or_finalize(bill_image) if result.status.in?(%i[analyzed failed])
  end

  # Album images are built by the album finalizer (after every image is OCR'd),
  # not immediately, so the whole album is reconciled in one place.
  def build_or_finalize(bill_image)
    if bill_image.bill_album_id
      FinalizeBillAlbumJob.perform_later(bill_image.bill_album_id)
    else
      BuildTransactionJob.perform_later(bill_image.id)
    end
  end

  private

  def reopen_album(bill_image)
    bill_image.bill_album.update!(status: "processing", reconciliation_status: nil)
  end
end
