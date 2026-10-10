class WriteHelloSmcWorkbookJob < ApplicationJob
  queue_as :exports

  retry_on Google::Apis::Error, wait: :polynomially_longer, attempts: 5

  def perform(transaction_id)
    transaction = Transaction.find(transaction_id)
    result = Workbook::HelloSmcWriter.call(transaction:)
    StructuredLog.info("workbook.hello_smc_written", transaction_id:, result:)
  end
end
