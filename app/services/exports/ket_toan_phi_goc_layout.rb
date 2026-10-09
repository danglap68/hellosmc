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

      # Active rules are small configuration. Load them once per export instead of
      # querying again for every MB/Napas row. The filters match covering_merchant,
      # assigned_to_merchant, assigned_to_card_type and effective_at.

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

      # Phí gốc của quy tắc gắn đúng hộ chọn sheet. Phí gốc theo thẻ, nếu có, đưa vào công thức.
      # Quy tắc không gắn hộ giữ cách cũ: sheet từ quy tắc hộ, công thức từ phí gốc của quy tắc thẻ.
      def place_special_card(transaction)
        rule = card_fee_rule(transaction)
        sheet_name = sheet_for_special(transaction, rule)
        return skip(transaction, "sheet_unmapped") if sheet_name.nil?

        formula_percent = KetToanPhiGocLayout.formula_percent_for(formula_rate_for(rule))
        # A card rule without its own dealer rate falls back to the dealer rate stored on the
        # transaction, which is what Transactions::Evaluator used when it priced the amount.
        dealer_rate = rule&.dealer_rate || transaction.applied_dealer_rate
        return skip(transaction, "dealer_rate_missing") if rule.nil? || dealer_rate.nil? || formula_percent.nil?
        return skip(transaction, "sheet_unmapped") if transaction.transaction_amount_vnd.nil?

        Placed.new(transaction:, sheet_name:, formula_percent:, dealer_rate:)
      end

      def sheet_for_special(transaction, rule)
        if rule && assigned_to_merchant?(rule, transaction.merchant_id)
          direct_sheet(rule.base_fee_rate) || household_sheet(transaction)
        else
          household_sheet(transaction)
        end
      end

      def assigned_to_merchant?(rule, merchant_id)
        return false if merchant_id.nil?

        rule.fee_rule_merchants.any? { |link| link.merchant_id == merchant_id }
      end

      def formula_rate_for(rule)
        return nil if rule.nil?

        rule.card_base_fee_rate || rule.base_fee_rate
      end

      def special_card?(transaction)
        SPECIAL_CARD_KEYS.include?(transaction.card_type&.key)
      end

      def rules
        @rules ||= FeeRule.active.includes(:fee_rule_merchants, :fee_rule_card_types).to_a
      end

      def household_card?(rule)
        ids = card_type_ids_for(rule)
        ids.empty? || (@normal_card_type_id && ids.include?(@normal_card_type_id))
      end

      def card_type_ids_for(rule)
        rule.fee_rule_card_types.map(&:card_type_id)
      end

      def covers_merchant?(rule, merchant_id)
        ids = rule.fee_rule_merchants.map(&:merchant_id)
        return ids.empty? if merchant_id.nil?

        ids.empty? || ids.include?(merchant_id)
      end

      def direct_sheet(rate)
        percent = KetToanPhiGocLayout.canonical_percent(rate)
        SHEETS.find { |sheet| sheet[:percent] == percent }&.fetch(:name)
      end

      def household_sheet(transaction)
        merchant = transaction.merchant
        at = transaction.transaction_at
        return nil if merchant.nil? || at.nil?

        grouped = {}
        rules.each do |rule|
          next unless rule.effective_at?(at)
          next unless rule.fee_rule_merchants.any? { |link| link.merchant_id == merchant.id }
          next unless household_card?(rule)

          sheet_name = direct_sheet(rule.base_fee_rate)
          next if sheet_name.nil?

          rank = card_type_ids_for(rule).any? ? 0 : 1
          (grouped[rank] ||= []) << [ rule, sheet_name ]
        end
        return nil if grouped.empty?

        ranked = grouped[grouped.keys.min]
        best_priority = ranked.map { |rule, _sheet| rule.priority }.min
        names = ranked.select { |rule, _sheet| rule.priority == best_priority }.map(&:last).uniq
        names.one? ? names.first : nil
      end

      # Most specific rule that targets this card: merchant+card, then dealer+card, then card only.
      def card_fee_rule(transaction)
        at = transaction.transaction_at
        card_type = transaction.card_type
        return nil if at.nil? || card_type.nil?

        dealer_ids = [ nil, transaction.dealer_id ].uniq
        matches = rules.select do |rule|
          rule.effective_at?(at) &&
            dealer_ids.include?(rule.dealer_id) &&
            covers_merchant?(rule, transaction.merchant_id) &&
            card_type_ids_for(rule).include?(card_type.id)
        end
        return nil if matches.empty?

        level = matches.group_by(&:specificity_rank).min_by(&:first).last
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
