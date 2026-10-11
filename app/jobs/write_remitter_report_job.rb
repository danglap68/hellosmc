class WriteRemitterReportJob < ApplicationJob
  queue_as :exports

  # Same retry policy as WriteHelloSmcWorkbookJob: both writers share the
  # per-spreadsheet lock, and the write is idempotent (RT<id> cell note).
  retry_on Workbook::HelloSmcWriter::LockBusy, wait: 3.seconds, attempts: 200, jitter: 0.5
  retry_on Google::Apis::Error, wait: :polynomially_longer, attempts: 5
  retry_on Google::Apis::RateLimitError, Google::Apis::ServerError, Google::Apis::TransmissionError,
           wait: ->(executions) { [ executions**2 * 5, 300 ].min }, attempts: 12, jitter: 0.3
  discard_on ActiveRecord::RecordNotFound
  discard_on Workbook::HelloSmcWriter::ConfigurationError do |_job, error|
    StructuredLog.error("workbook.hello_smc_configuration_error", error: error.message)
  end

  def perform(remitter_transfer_id)
    transfer = RemitterTransfer.find(remitter_transfer_id)
    result = Workbook::RemitterReportWriter.call(remitter_transfer: transfer)
    StructuredLog.info("workbook.remitter_report_written", remitter_transfer_id:, result:)
  end
end
