module Transactions
  # Takes an excluded bill (SmartPOS, HKD "Bỏ qua bill") into the accounting flow:
  # the tag goes, the bill is built like any other (fee, agent, review) and is not
  # excluded again on a rerun. For reconciliation or after a rule changed.
  class Includer
    def self.call(transaction:, actor: nil)
      new(transaction:, actor:).call
    end

    def initialize(transaction:, actor:)
      @transaction = transaction
      @actor = actor
    end

    def call
      included = false
      Transaction.transaction do
        @transaction.lock!
        bill_image = @transaction.bill_image
        unless @transaction.excluded? && bill_image && !@transaction.source_data["excluded_reason"].in?(%w[child_receipt album_duplicate])
          @transaction.errors.add(:base, :not_excludable)
          raise ActiveRecord::Rollback
        end

        before = @transaction.audit_snapshot
        @transaction.update!(tags: [], source_data: @transaction.source_data.merge("force_include" => true))
        @transaction.transition_to!("processing")
        Builder.call(bill_image: bill_image)

        if @transaction.reload.processing?
          @transaction.errors.add(:base, :not_excludable)
          raise ActiveRecord::Rollback
        end

        AuditLogger.log!(actor: @actor, action: "transaction.included", auditable: @transaction,
                         before_data: before, after_data: @transaction.audit_snapshot)
        included = true
      end
      included
    end
  end
end
