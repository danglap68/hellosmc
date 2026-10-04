module Transactions
  # Re-runs OCR for the transaction's bill image; the builder then rebuilds
  # this transaction (only rows in `processing` are ever rebuilt).
  class Reprocessor
    def self.call(transaction:, actor:)
      new(transaction:, actor:).call
    end

    def initialize(transaction:, actor:)
      @transaction = transaction
      @actor = actor
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

        before = @transaction.audit_snapshot
        @transaction.transition_to!("processing")
        @transaction.open_review&.update!(status: "superseded")
        AuditLogger.log!(actor: @actor, action: "transaction.reprocess_requested", auditable: @transaction,
                         before_data: before, after_data: @transaction.audit_snapshot)
        requested = true
      end
      return false unless requested

      AnalyzeBillImageJob.perform_later(@transaction.bill_image_id, force: true)
      true
    end
  end
end
