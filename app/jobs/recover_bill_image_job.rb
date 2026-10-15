class RecoverBillImageJob < ApplicationJob
  queue_as :ocr

  def self.schedule(image_id)
    image = BillImage.find(image_id)
    image.with_lock do
      run_id = image.metadata.dig("vision_pipeline", "run_id")
      return if run_id.blank? || !image.ocr_runs_remaining? || image.metadata["recovery_job_run_id"] == run_id

      image.update!(metadata: image.metadata.merge("recovery_job_run_id" => run_id))
      ActiveRecord.after_all_transactions_commit { set(wait: 1.minute).perform_later(image_id, run_id: run_id) }
    end
  end

  def perform(bill_image_id, run_id: nil)
    image = BillImage.find_by(id: bill_image_id)
    BillImages::SystemRecovery.call(image, expected_run_id: run_id) if image
  end
end
