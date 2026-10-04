module Transactions
  # Possible duplicates: same merchant and amount, and either
  #   * transaction time within the duplicate window (admin setting), or
  #   * the same lot number on the same business day.
  # Hard duplicates (same Telegram message, same file, same bytes, same
  # settlement index of an image) are stopped earlier by unique constraints.
  class DuplicateDetector
    Result = Data.define(:possible_duplicate_ids) do
      def possible_duplicate?
        possible_duplicate_ids.any?
      end
    end

    def self.call(transaction)
      new(transaction).call
    end

    def initialize(transaction)
      @transaction = transaction
    end

    def call
      t = @transaction
      return Result.new(possible_duplicate_ids: []) unless t.merchant_id && t.transaction_amount_vnd && t.transaction_at

      scope = Transaction.not_rejected
        .where(merchant_id: t.merchant_id, transaction_amount_vnd: t.transaction_amount_vnd)
      scope = scope.where.not(id: t.id) if t.persisted?

      window = AppConfig.duplicate_window_minutes.minutes
      near_in_time = scope.where(transaction_at: (t.transaction_at - window)..(t.transaction_at + window))
      ids = near_in_time.pluck(:id)

      if t.lot_number.present?
        day = t.transaction_at.in_time_zone.all_day
        ids |= scope.where(lot_number: t.lot_number, transaction_at: day).pluck(:id)
      end

      Result.new(possible_duplicate_ids: ids.sort)
    end
  end
end
