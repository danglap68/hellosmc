class WriteHelloSmcWorkbookJob < ApplicationJob
  queue_as :exports

  # Another job holds the per-spreadsheet lock: wait a moment instead of
  # blocking a Sidekiq thread (and its DB connection) on the lock.
  retry_on Workbook::HelloSmcWriter::LockBusy, wait: 3.seconds, attempts: 30, jitter: 0.5
  # The write is idempotent (TX marker on the ledger rows), so retrying a
  # timeout that may have been applied is safe.
  retry_on Google::Apis::Error, wait: :polynomially_longer, attempts: 5
  # The transaction was deleted before the job ran; nothing to write.
  discard_on ActiveRecord::RecordNotFound
  # A blank spreadsheet id won't fix itself on retry; log it loudly and discard
  # instead of flooding the retry queue for every new transaction.
  discard_on Workbook::HelloSmcWriter::ConfigurationError do |_job, error|
    StructuredLog.error("workbook.hello_smc_configuration_error", error: error.message)
  end

  def perform(transaction_id)
    transaction = Transaction.find(transaction_id)
    result = Workbook::HelloSmcWriter.call(transaction:)
    StructuredLog.info("workbook.hello_smc_written", transaction_id:, result:)
  end
end
