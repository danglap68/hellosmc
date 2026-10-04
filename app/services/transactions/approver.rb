module Transactions
  # Human approval. Locks the row, re-checks its current status, recomputes
  # the amounts deterministically from the snapshotted rate (resolving a rule
  # only if none was ever applied) and refuses incomplete transactions.
  class Approver
    REQUIRED = %i[dealer merchant card_type transaction_at transaction_amount_vnd].freeze
    APPROVABLE_STATUSES = %w[needs_review hold failed].freeze

    def self.call(transaction:, actor:, note: nil)
      new(transaction:, actor:, note:).call
    end

    def initialize(transaction:, actor:, note:)
      @transaction = transaction
      @actor = actor
      @note = note.presence
    end

    def call
      approved = false
      Transaction.transaction do
        @transaction.lock!
        unless @transaction.status.in?(APPROVABLE_STATUSES)
          @transaction.errors.add(:base, :cannot_approve_from)
          raise ActiveRecord::Rollback
        end

        before = @transaction.audit_snapshot
        @transaction.transition_to!("needs_review") if @transaction.failed?

        recalculation = Recalculator.call(@transaction, resolve: false)
        validate_complete(recalculation)
        raise ActiveRecord::Rollback if @transaction.errors.any?

        @transaction.transition_to!("approved", approved_by: @actor, approved_at: Time.current)
        close_review
        AuditLogger.log!(actor: @actor, action: "transaction.approved", auditable: @transaction,
                         before_data: before, after_data: @transaction.audit_snapshot,
                         metadata: { "note" => @note }.compact)
        approved = true
      end
      return false unless approved

      StructuredLog.info("transaction.review_decision", transaction_id: @transaction.id, decision: "approved",
                                                        user_id: @actor&.id)
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    private

    def validate_complete(recalculation)
      REQUIRED.each do |attribute|
        @transaction.errors.add(attribute, :blank) if @transaction.public_send(attribute).blank?
      end
      return if recalculation.calculated?

      error = recalculation.fee_status == :ambiguous ? :fee_rule_ambiguous : :fee_rule_not_found
      @transaction.errors.add(:fee_rule, error)
    end

    def close_review
      review = @transaction.open_review ||
        @transaction.reviews.build(reason: "manual_decision", reason_codes: [], original_values: {})
      review.update!(status: "approved", reviewed_by: @actor, reviewed_at: Time.current, note: @note || review.note)
    end
  end
end
