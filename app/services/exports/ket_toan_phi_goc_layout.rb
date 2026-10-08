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

    class SheetPicker
      def initialize
        @normal_card_type_id = CardType.find_by(key: "normal")&.id
      end

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

      # Sheet from the household's normal fee. Formula percent and column D from the card rule.
      def place_special_card(transaction)
        sheet_name = household_sheet(transaction)
        return skip(transaction, "sheet_unmapped") if sheet_name.nil?

        rule = card_fee_rule(transaction)
        formula_percent = KetToanPhiGocLayout.formula_percent_for(rule&.base_fee_rate)
        if rule.nil? || rule.dealer_rate.nil? || formula_percent.nil?
          return skip(transaction, "dealer_rate_missing")
        end
        return skip(transaction, "sheet_unmapped") if transaction.transaction_amount_vnd.nil?

        Placed.new(transaction:, sheet_name:, formula_percent:, dealer_rate: rule.dealer_rate)
      end

      def special_card?(transaction)
        SPECIAL_CARD_KEYS.include?(transaction.card_type&.key)
      end

      def household_card?(rule)
        ids = rule.fee_rule_card_types.map(&:card_type_id)
        ids.empty? || (@normal_card_type_id && ids.include?(@normal_card_type_id))
      end

      def direct_sheet(rate)
        percent = KetToanPhiGocLayout.canonical_percent(rate)
        SHEETS.find { |sheet| sheet[:percent] == percent }&.fetch(:name)
      end

      def household_sheet(transaction)
        merchant = transaction.merchant
        at = transaction.transaction_at
        return nil if merchant.nil? || at.nil?

        rules = FeeRule.active.effective_at(at)
          .assigned_to_merchant(merchant.id)
          .includes(:fee_rule_card_types)
          .select { |rule| household_card?(rule) && direct_sheet(rule.base_fee_rate) }
        return nil if rules.empty?

        ranked = rules.group_by { |rule| rule.fee_rule_card_types.any? ? 0 : 1 }.min_by(&:first).last
        best_priority = ranked.map(&:priority).min
        chosen = ranked.select { |rule| rule.priority == best_priority }
        names = chosen.map { |rule| direct_sheet(rule.base_fee_rate) }.uniq
        names.one? ? names.first : nil
      end

      # Most specific rule that targets this card: merchant+card, then dealer+card, then card only.
      def card_fee_rule(transaction)
        at = transaction.transaction_at
        card_type = transaction.card_type
        return nil if at.nil? || card_type.nil?

        rules = FeeRule.active.effective_at(at)
          .covering_merchant(transaction.merchant_id)
          .assigned_to_card_type(card_type.id)
          .where(dealer_id: [ nil, transaction.dealer_id ].uniq)
          .to_a
        return nil if rules.empty?

        level = rules.group_by(&:specificity_rank).min_by(&:first).last
        best_priority = level.map(&:priority).min
        chosen = level.select { |rule| rule.priority == best_priority }
        chosen.one? ? chosen.first : nil
      end

      def skip(transaction, reason)
        Skip.new(transaction:, reason:)
      end
    end
  end
end
