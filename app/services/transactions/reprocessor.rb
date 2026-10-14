module Transactions
  # Re-runs OCR for the transaction's bill image; the builder then rebuilds
  # this transaction (only rows in `processing` are ever rebuilt).
  class Reprocessor
    def self.call(transaction:, actor:, enqueue: true)
      new(transaction:, actor:, enqueue:).call
    end

    def initialize(transaction:, actor:, enqueue:)
      @transaction = transaction
      @actor = actor
      @enqueue = enqueue
    end

    def call
      requested = false
      Transaction.transaction do
        @transaction.lock!
        # Re-check the persisted image budget; hiding a button is not a guard.
        @transaction.bill_image&.reload
        unless @transaction.reprocessable?
          @transaction.errors.add(:base, :not_reprocessable)
          raise ActiveRecord::Rollback
        end

        before = @transaction.audit_snapshot.merge(
          @transaction.source_data.slice("review_reasons", "possible_duplicate_ids", "ocr_error")
        )
        @transaction.source_data = @transaction.source_data.except("possible_duplicate_ids", "ocr_error")
          .merge("review_reasons" => [])
        @transaction.transition_to!("processing")
        @transaction.open_review&.update!(status: "superseded")
        AuditLogger.log!(actor: @actor, action: "transaction.reprocess_requested", auditable: @transaction,
                         before_data: before, after_data: @transaction.audit_snapshot.merge("review_reasons" => []))
        requested = true
      end
      return false unless requested

      image_id = @transaction.bill_image_id
      ActiveRecord.after_all_transactions_commit { AnalyzeBillImageJob.perform_later(image_id, force: true) } if @enqueue
      true
    end
  end
end
