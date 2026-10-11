# Safety net for the Hello SMC sheet, run periodically
# (`bin/rails hellosmc:retry_workbook_writes`, e.g. every 10 minutes).
#
# A WriteHelloSmcWorkbookJob can run out of retries (Google quota or outage) or
# be lost with a Redis restart. The transaction is then approved but missing
# from the sheet, and nothing else would ever notice. This enqueues the write
# again for every finalized transaction that has no WorkbookEntry yet, and for
# every approved remitter transfer not written to its "thu chi" tab. Safe to
# repeat: the writer is idempotent (TX marker) and takes a per-sheet lock.
class RetryWorkbookWritesJob < ApplicationJob
  queue_as :exports

  # Leave jobs that are still in flight (or waiting for their retry) alone.
  GRACE = 15.minutes
  BATCH = 200

  def perform
    return if AppConfig.hello_smc_spreadsheet_id.blank?

    ids = pending.limit(BATCH).pluck(:id)
    # Spread the load: the writer is serialized per spreadsheet anyway.
    ids.each_with_index { |id, index| WriteHelloSmcWorkbookJob.set(wait: index * 2.seconds).perform_later(id) }
    transfer_ids = pending_transfers.limit(BATCH).pluck(:id)
    transfer_ids.each_with_index do |id, index|
      WriteRemitterReportJob.set(wait: (ids.size + index) * 2.seconds).perform_later(id)
    end
    total = ids.size + transfer_ids.size
    StructuredLog.info("workbook.retry_pending", count: ids.size, transfers: transfer_ids.size) if total.positive?
    total
  end

  private

  def pending
    Transaction.where(status: Transaction::FINALIZED_STATUSES)
      .where.not(transaction_amount_vnd: nil).where.not(transaction_at: nil)
      .where(updated_at: ...GRACE.ago)
      .where.missing(:workbook_entry)
      .order(:id)
  end

  # Approved remitter transfers whose write job was lost or ran out of
  # retries. A transfer the writer could not place (no day tab, no agent block,
  # …) carries metadata.write_issue and waits for a person to fix the sheet and
  # press "Ghi lại", instead of being re-read every run.
  def pending_transfers
    RemitterTransfer.pending_write.where.not(merchant_dealer_id: nil).where.not(remitter_id: nil)
      .where("remitter_transfers.metadata->>'write_issue' IS NULL")
      .where(updated_at: ...GRACE.ago).order(:id)
  end
end
