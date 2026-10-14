module Transactions
  # Possible duplicates: same merchant and amount, and either
  #   * transaction time within the duplicate window (admin setting), or
  #   * the same lot number on the same business day.
  # Hard duplicates (same Telegram message, same file, same bytes, same
  # settlement index of an image) are stopped earlier by unique constraints.
  # An identical settlement identity is also suspicious when OCR read a
  # different amount: requiring equal amounts would hide that contradiction.
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

      merchant_scope = Transaction.not_rejected.where.not(status: "excluded").where(merchant_id: t.merchant_id)
      merchant_scope = merchant_scope.where.not(id: t.id) if t.persisted?
      scope = merchant_scope.where(transaction_amount_vnd: t.transaction_amount_vnd)

      window = AppConfig.duplicate_window_minutes.minutes
      near_in_time = scope.where(transaction_at: (t.transaction_at - window)..(t.transaction_at + window))
      ids = near_in_time.pluck(:id)

      if t.lot_number.present?
        day = t.transaction_at.in_time_zone.all_day
        ids |= scope.where(lot_number: t.lot_number, transaction_at: day).pluck(:id)
      end

      identifier = VietnameseText.normalize_identifier(t.extraction["terminal_or_merchant_id"])
      if t.extraction["document_type"] == "settlement" && t.lot_number.present? && identifier.present?
        identical = merchant_scope.where(lot_number: t.lot_number, transaction_at: t.transaction_at).select do |other|
          other.extraction["document_type"] == "settlement" &&
            VietnameseText.normalize_identifier(other.extraction["terminal_or_merchant_id"]) == identifier
        end
        ids |= identical.map(&:id)
      end

      Result.new(possible_duplicate_ids: ids.sort)
    end
  end
end
