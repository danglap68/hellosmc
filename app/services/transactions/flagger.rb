module Transactions
  # Sends already-built transactions back to a human when their source
  # changed after the fact (e.g. the Telegram caption with the card-type tag
  # was edited). Booked rows are put on hold; rows still in review get the
  # extra reason. Rows being processed will pick up the change themselves.
  class Flagger
    def self.call(transactions:, reason:, actor: nil)
      new(transactions:, reason:, actor:).call
    end

    def initialize(transactions:, reason:, actor:)
      @transactions = transactions
      @reason = reason
      @actor = actor
    end

    def call
      @transactions.filter_map { |transaction| flag(transaction) }
    end

    private

    def flag(transaction)
      Transaction.transaction do
        transaction.lock!
        next nil unless transaction.status.in?(%w[approved exported needs_review hold failed])

        before = transaction.audit_snapshot
        reasons = (transaction.review_reason_codes | [ @reason ])
        transaction.source_data = transaction.source_data.merge("review_reasons" => reasons)

        if transaction.status.in?(%w[approved exported])
          transaction.transition_to!("hold")
          transaction.reviews.create!(status: "held", reason: @reason, reason_codes: [ @reason ], original_values: {})
        else
          transaction.save!
          transaction.open_review&.update!(reason_codes: transaction.open_review.reason_codes | [ @reason ])
        end

        AuditLogger.log!(actor: @actor, action: "transaction.flagged", auditable: transaction,
                         before_data: before, after_data: transaction.audit_snapshot,
                         metadata: { "reason" => @reason })
        transaction
      end
    end
  end
end
