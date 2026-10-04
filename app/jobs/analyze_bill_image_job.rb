class AnalyzeBillImageJob < ApplicationJob
  queue_as :ocr

  # Transient provider failures are retried; when retries run out the bill is
  # marked failed and still surfaces as a failed transaction for a human.
  retry_on BillVision::TransientError, wait: :polynomially_longer, attempts: 3 do |job, error|
    bill_image = BillImage.find_by(id: job.arguments.first)
    if bill_image && BillImages::Analyzer.mark_failed!(bill_image, error, job_id: job.job_id)
      BuildTransactionJob.perform_later(bill_image.id)
    end
  end

  def perform(bill_image_id, force: false)
    bill_image = BillImage.find(bill_image_id)
    result = BillImages::Analyzer.call(bill_image, force: force, job_id: job_id)
    BuildTransactionJob.perform_later(bill_image.id) if result.status.in?(%i[analyzed failed])
  end
end
