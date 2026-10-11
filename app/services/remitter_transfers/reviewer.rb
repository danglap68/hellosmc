module RemitterTransfers
  # A person's decision on a RemitterTransfer: approve (optionally correcting
  # the code, amount or remitter) or reject. Approval queues the "thu chi"
  # write. A transfer already written to the sheet is never changed here: the
  # sheet has to be corrected by hand.
  class Reviewer
    Result = Data.define(:ok, :errors) do
      def ok? = ok
    end

    def self.approve(transfer:, actor:, code: nil, amount: nil, remitter_id: nil, lock_version: nil)
      new(transfer, actor).approve(code:, amount:, remitter_id:, lock_version:)
    end

    def self.reject(transfer:, actor:, lock_version: nil)
      new(transfer, actor).reject(lock_version:)
    end

    def initialize(transfer, actor)
      @transfer = transfer
      @actor = actor
    end

    def approve(code:, amount:, remitter_id:, lock_version:)
      errors = []
      RemitterTransfer.transaction do
        @transfer.lock!
        errors << :stale if stale?(lock_version)
        errors << :already_written if @transfer.written?
        raise ActiveRecord::Rollback if errors.any?

        before = snapshot
        code = code.to_s.strip.upcase.presence || @transfer.transfer_code
        link = code && Codes.merchant_dealer_for(code)
        parsed = parse_amount(amount)
        amount = parsed == :invalid ? nil : (parsed || @transfer.amount_vnd)
        remitter = remitter_id.present? ? Remitter.find_by(id: remitter_id) : @transfer.remitter
        errors << :code_invalid unless link
        errors << :amount_invalid unless amount&.positive?
        errors << :remitter_missing unless remitter
        raise ActiveRecord::Rollback if errors.any?

        @transfer.update!(
          transfer_code: code, merchant_dealer: link, merchant: link.merchant, amount_vnd: amount, remitter: remitter,
          code_source: code == @transfer.transfer_code && @transfer.code_source ? @transfer.code_source : "manual",
          status: "approved", review_reasons: [], reviewed_by: @actor, reviewed_at: Time.current
        )
        AuditLogger.log!(actor: @actor, action: "remitter_transfer.approved", auditable: @transfer,
                         before_data: before, after_data: snapshot)
        id = @transfer.id
        ActiveRecord.after_all_transactions_commit { WriteRemitterReportJob.perform_later(id) }
      end
      Result.new(ok: errors.empty?, errors: errors)
    end

    def reject(lock_version:)
      errors = []
      RemitterTransfer.transaction do
        @transfer.lock!
        errors << :stale if stale?(lock_version)
        errors << :already_written if @transfer.written?
        raise ActiveRecord::Rollback if errors.any?

        before = snapshot
        @transfer.update!(status: "rejected", reviewed_by: @actor, reviewed_at: Time.current)
        AuditLogger.log!(actor: @actor, action: "remitter_transfer.rejected", auditable: @transfer,
                         before_data: before, after_data: snapshot)
      end
      Result.new(ok: errors.empty?, errors: errors)
    end

    private

    def stale?(lock_version)
      lock_version.present? && lock_version.to_i != @transfer.lock_version
    end

    # Whole VND only: "29274000", "29.274.000", "29,274,000 ₫" -> 29274000.
    # Anything else ("29.5", "-100", "29tr") is rejected, not guessed.
    AMOUNT = /\A\d{1,3}(?:[.,\s]\d{3})+\z|\A\d+\z/

    def parse_amount(value)
      text = value.to_s.strip.sub(/\s*(?:₫|đ|vnd)\z/i, "")
      return nil if text.empty?
      return :invalid unless text.match?(AMOUNT)

      text.gsub(/\D/, "").to_i
    end

    def snapshot
      @transfer.attributes.slice("status", "transfer_code", "merchant_dealer_id", "amount_vnd", "remitter_id",
                                 "review_reasons")
    end
  end
end
