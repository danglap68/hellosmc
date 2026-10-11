class BuildRemitterTransferJob < ApplicationJob
  queue_as :default

  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(remitter_transfer_id)
    transfer = RemitterTransfers::Builder.call(remitter_transfer: RemitterTransfer.find(remitter_transfer_id))
    StructuredLog.info("remitter_transfer.built", job_id: job_id, remitter_transfer_id: transfer.id,
                                                  status: transfer.status, reasons: transfer.review_reasons)
  end
end
