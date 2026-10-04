# Housekeeping for OCR, run periodically (`bin/rails hellosmc:retry_failed_extractions`):
# * bills stuck in `processing` (worker crash, lost job) are marked failed so
#   they surface as failed transactions;
# * failed bills with runs left (setting max_ocr_attempts) are analyzed again.
class RetryFailedExtractionJob < ApplicationJob
  queue_as :ocr

  STUCK_AFTER = 30.minutes

  def perform
    release_stuck
    retry_failed
  end

  private

  def release_stuck
    BillImage.analyzable.where(ocr_status: "processing").where(updated_at: ...STUCK_AFTER.ago).find_each do |bill_image|
      if BillImages::Analyzer.mark_failed!(bill_image, StandardError.new("OCR run abandoned (stuck in processing)"), stale_before: STUCK_AFTER.ago)
        BuildTransactionJob.perform_later(bill_image.id)
      end
    end
  end

  def retry_failed
    BillImage.analyzable.where(ocr_status: "failed").where("ocr_attempts < ?", AppConfig.max_ocr_attempts)
      .where("metadata->>'ocr_retryable' IS DISTINCT FROM 'false'")
      .find_each do |bill_image|
        reprocess_transactions(bill_image)
        AnalyzeBillImageJob.perform_later(bill_image.id, force: true)
      end
  end

  def reprocess_transactions(bill_image)
    bill_image.transactions.where(status: "failed").find_each do |transaction|
      transaction.transition_to!("processing")
      AuditLogger.log!(action: "transaction.reprocess_requested", auditable: transaction,
                       metadata: { "trigger" => "retry_failed_extraction" })
    end
  end
end
