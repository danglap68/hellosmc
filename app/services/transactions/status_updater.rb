module Transactions
  # Hold / reject decisions with audit trail and review bookkeeping.
  # The row is locked and its current status re-checked before changing it.
  class StatusUpdater
    ACTIONS = {
      "hold" => { status: "hold", review_status: "held", audit: "transaction.held" },
      "reject" => { status: "rejected", review_status: "rejected", audit: "transaction.rejected" }
    }.freeze

    def self.call(transaction:, actor:, action:, note: nil)
      new(transaction:, actor:, action:, note:).call
    end

    def initialize(transaction:, actor:, action:, note:)
      @transaction = transaction
      @actor = actor
      @config = ACTIONS.fetch(action.to_s)
      @note = note.presence
    end

    def call
      changed = false
      Transaction.transaction do
        @transaction.lock!
        unless @transaction.can_transition_to?(@config[:status])
          @transaction.errors.add(:base, :invalid_transition)
          raise ActiveRecord::Rollback
        end

        before = @transaction.audit_snapshot
        @transaction.transition_to!(@config[:status])
        review = @transaction.open_review ||
          @transaction.reviews.build(reason: "manual_decision", reason_codes: [], original_values: {})
        review.update!(status: @config[:review_status], reviewed_by: @actor, reviewed_at: Time.current,
                       note: @note || review.note)
        AuditLogger.log!(actor: @actor, action: @config[:audit], auditable: @transaction,
                         before_data: before, after_data: @transaction.audit_snapshot,
                         metadata: { "note" => @note }.compact)
        changed = true
      end
      return false unless changed

      StructuredLog.info("transaction.review_decision", transaction_id: @transaction.id,
                                                        decision: @config[:status], user_id: @actor&.id)
      true
    end
  end
end
