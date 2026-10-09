module Exports
  # Workbook "Kết toán theo phí gốc": one sheet per base-fee tier.
  # Rows are chosen when the file is built, from rates already stored on the transaction.
  module KetToanPhiGocLayout
    SHEETS = [
      { name: "1,21", percent: BigDecimal("1.21"), formula: "1.21%" },
      { name: "1,17", percent: BigDecimal("1.17"), formula: "1.17%" },
      { name: "1,15", percent: BigDecimal("1.15"), formula: "1.15%" }
    ].freeze
    SHEET_NAMES = SHEETS.map { |sheet| sheet[:name] }.freeze
    SPECIAL_CARD_KEYS = %w[mb napas].freeze
    PREVIEW_HEADERS = [
      "Số tiền giao dịch",
      "Số tiền đã khấu trừ cho đại lý",
      "Số tiền sau khi trừ phí gốc",
      "Tỷ lệ",
      "Lợi nhuận",
      "Số Lô",
      "Ngày giao dịch",
      "Giờ giao dịch",
      "Tên đại lý",
      "Tên HKD"
    ].freeze

    Placed = Data.define(:transaction, :sheet_name, :formula_percent, :dealer_rate)
    Skip = Data.define(:transaction, :reason)

    module_function

    def partition(transactions)
      picker = SheetPicker.new
      placed = []
      skipped = []
      transactions.each do |transaction|
        result = picker.place(transaction)
        if result.is_a?(Skip)
          skipped << { "transaction_id" => transaction.id, "reason" => result.reason }
        else
          placed << result
        end
      end
      [ placed, skipped ]
    end

    def headers_for(_sheet_name)
      [
        "Số tiền giao dịch",
        "Số tiền đã khấu trừ cho đại lý",
        "Số tiền sau khi trừ phí gốc \n(1,21% với thẻ thường, thẻ MB - 0,88%)",
        "Tỷ lệ",
        "Lợi nhuận",
        "Số Lô",
        "Ngày giao dịch",
        "Giờ giao dịch",
        "Tên đại lý",
        "Tên HKD"
      ]
    end

    def formulas(row_number, formula_percent)
      {
        b: "=A#{row_number}-(A#{row_number}*D#{row_number})",
        c: "=A#{row_number}-(A#{row_number}*#{formula_percent})",
        e: "=A#{row_number}*(D#{row_number}-#{formula_percent})"
      }
    end

    def sum_formulas(last_data_row)
      {
        a: "=SUM(A2:A#{last_data_row})",
        b: "=SUM(B2:B#{last_data_row})",
        c: "=SUM(C2:C#{last_data_row})",
        e: "=SUM(E2:E#{last_data_row})"
      }
    end

    # Percent points (1.21, not 0.0121). Only values already at two decimal places match.
    # 1.210000 is 1.21. 1.211 is not.
    def canonical_percent(rate)
      return nil if rate.nil?

      points = BigDecimal(rate.to_s) * 100
      rounded = points.round(2)
      rounded if points == rounded
    end

    # "0.88%" from a stored rate of 0.0088. Nil when the rate is not an exact two-decimal percent.
    def formula_percent_for(rate)
      points = canonical_percent(rate)
      format("%.2f%%", points) if points
    end

    # Reads only what was stored on the transaction when it was priced, so a later edit to a
    # fee rule cannot make the file disagree with the saved amounts.
    class SheetPicker
      def place(transaction)
        return place_special_card(transaction) if special_card?(transaction)

        place_standard(transaction)
      end

      private

      def place_standard(transaction)
        sheet_name = direct_sheet(transaction.applied_base_fee_rate)
        return skip(transaction, "sheet_unmapped") if sheet_name.nil?
        return skip(transaction, "dealer_rate_missing") if transaction.applied_dealer_rate.nil?
        return skip(transaction, "sheet_unmapped") if transaction.transaction_amount_vnd.nil?

        Placed.new(
          transaction:,
          sheet_name:,
          formula_percent: SHEETS.find { |sheet| sheet[:name] == sheet_name }.fetch(:formula),
          dealer_rate: transaction.applied_dealer_rate
        )
      end

      # The sheet is the household tier. The formula uses the rate the amount was priced with
      # (card base fee if there is one, else the base fee) and the dealer rate stored with it.
      def place_special_card(transaction)
        sheet_name = special_sheet(transaction)
        return skip(transaction, "sheet_unmapped") if sheet_name.nil?

        formula_percent = KetToanPhiGocLayout.formula_percent_for(
          transaction.applied_card_base_fee_rate || transaction.applied_base_fee_rate
        )
        dealer_rate = transaction.applied_dealer_rate
        return skip(transaction, "dealer_rate_missing") if dealer_rate.nil? || formula_percent.nil?
        return skip(transaction, "sheet_unmapped") if transaction.transaction_amount_vnd.nil?

        Placed.new(transaction:, sheet_name:, formula_percent:, dealer_rate:)
      end

      # A winning rule that is configured with this household and carries a tier gives the sheet.
      # Otherwise (a card-only rule, or a household rule whose base fee is a card rate) use the
      # household tier stored when the transaction was priced.
      def special_sheet(transaction)
        own = direct_sheet(transaction.applied_base_fee_rate) if winning_rule_has_household?(transaction)
        own || direct_sheet(household_rate(transaction))
      end

      def winning_rule_has_household?(transaction)
        merchant_id = transaction.merchant_id
        merchant_id.present? && Array(transaction.calculation_data.dig("fee_rule", "merchant_ids")).include?(merchant_id)
      end

      # Transactions priced before the household tier was stored have no key and fall back to
      # the current rules.
      def household_rate(transaction)
        data = transaction.calculation_data
        return data["household_base_fee_rate"]&.then { |value| BigDecimal(value) } if data.key?("household_base_fee_rate")

        FeeRules::Resolver.household_base_fee_rate(merchant: transaction.merchant, at: transaction.transaction_at)
      end

      def special_card?(transaction)
        SPECIAL_CARD_KEYS.include?(transaction.card_type&.key)
      end

      def direct_sheet(rate)
        percent = KetToanPhiGocLayout.canonical_percent(rate)
        SHEETS.find { |sheet| sheet[:percent] == percent }&.fetch(:name)
      end

      def skip(transaction, reason)
        Skip.new(transaction:, reason:)
      end
    end
  end
end
