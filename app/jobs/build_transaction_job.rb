class BuildTransactionJob < ApplicationJob
  queue_as :default

  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5

  def perform(bill_image_id)
    bill_image = BillImage.find(bill_image_id)
    transactions = Transactions::Builder.call(bill_image: bill_image)
    StructuredLog.info("transaction.build_finished", job_id: job_id, bill_image_id: bill_image.id,
                                                     transaction_ids: transactions.map(&:id))
  end
end
