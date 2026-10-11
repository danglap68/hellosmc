class WriteHelloSmcWorkbookJob < ApplicationJob
  queue_as :exports

  retry_on Google::Apis::Error, wait: :polynomially_longer, attempts: 5
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
