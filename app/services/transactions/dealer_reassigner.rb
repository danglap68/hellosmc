module Transactions
  # Moves an approved transaction that is not in the workbook yet to another
  # dealer without asking for a new approval. Used when the agent row behind
  # the bill changed hands (the DS MB header named another person) after the
  # bill was evaluated.
  #
  # Corrector only edits needs_review / hold / failed, so the bill steps
  # approved -> hold -> (Corrector: dealer, fee recalculated) -> approved, with
  # the original approver and time kept. Transactions::Approver is not used: it
  # would queue the workbook write that is already running.
  #
  # Runs in a savepoint: any failure leaves the transaction exactly as it was.
  class DealerReassigner
    Result = Data.define(:success, :reason) do
      def success?
        success
      end
    end

    def self.call(transaction:, dealer:, source:)
      new(transaction:, dealer:, source:).call
    end

    def initialize(transaction:, dealer:, source:)
      @transaction = transaction
      @dealer = dealer
      @source = source
    end

    def call
      result = nil
      Transaction.transaction(requires_new: true) do
        @transaction.lock!
        result = reassign
        raise ActiveRecord::Rollback unless result.success?
      end
      # The rollback restored the row, not this object (status, lock_version).
      @transaction.reload unless result.success?
      result
    rescue ActiveRecord::ActiveRecordError, Transaction::InvalidTransition, PaymentQrs::Error => error
      @transaction.reload
      Result.new(success: false, reason: error.message.to_s.truncate(200))
    end

    private

    def reassign
      return failure("already_in_workbook") if @transaction.booked?
      return failure("not_approved") unless @transaction.approved?
      return Result.new(success: true, reason: nil) if @transaction.dealer_id == @dealer.id
      # A confirmed QR may already have paid the previous dealer: a person decides.
      return failure("payment_qr_confirmed") if DealerPaymentQr.confirmed.exists?(transaction_id: @transaction.id)

      before = @transaction.audit_snapshot
      approved_by = @transaction.approved_by
      approved_at = @transaction.approved_at
      previous_dealer = @transaction.dealer

      @transaction.transition_to!("hold")
      corrected = Corrector.call(transaction: @transaction, actor: nil, params: { "dealer_id" => @dealer.id },
                                 note: "Đại lý đổi theo Google Sheet")
      return failure("correction_failed") unless corrected.success?
      return failure("fee_rule_missing") if @transaction.dealer_amount_vnd.blank? || @transaction.applied_dealer_rate.nil?

      @transaction.transition_to!("approved", approved_by:, approved_at:)
      refresh_payment_qr
      AuditLogger.log!(action: "transaction.dealer_reassigned", auditable: @transaction,
                       before_data: before, after_data: @transaction.audit_snapshot,
                       metadata: { "source" => @source, "from_dealer_id" => previous_dealer&.id,
                                   "to_dealer_id" => @dealer.id })
      Result.new(success: true, reason: nil)
    end

    # The request made at approval names the previous dealer's account: remake
    # it for the new dealer (it comes out blocked when that dealer has no bank
    # profile yet). Without a request, one is made only where it is automatic.
    def refresh_payment_qr
      request = DealerPaymentQr.find_by(transaction_id: @transaction.id)
      if request
        PaymentQrs::Prepare.call(@transaction, actor: nil, refresh: true)
      elsif @transaction.dealer&.auto_payment_qr?
        PaymentQrs::Prepare.call(@transaction, actor: nil)
      end
    end

    def failure(reason)
      Result.new(success: false, reason: reason)
    end
  end
end
