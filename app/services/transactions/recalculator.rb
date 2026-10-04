module Transactions
  # Recalculates every amount deterministically. Assigns attributes; the
  # caller saves.
  #
  # resolve: true  -> re-resolve the fee rule from the transaction's current
  #                   merchant/dealer/card type/time (or use a reviewer override);
  # resolve: false -> keep the rates already snapshotted on the transaction and
  #                   only recompute the amounts (falls back to resolving when
  #                   no rate was ever applied).
  class Recalculator
    Result = Data.define(:fee_rule, :fee_status) do
      def calculated?
        fee_status.in?(%i[resolved override snapshot])
      end
    end

    RESOLUTION_INPUTS = %w[merchant_id dealer_id card_type_id transaction_at].freeze

    def self.blank_calculation
      {
        applied_base_fee_rate: nil, amount_after_base_fee_vnd: nil, applied_dealer_rate: nil,
        dealer_amount_vnd: nil, profit_amount_vnd: nil, calculation_data: {}
      }
    end

    def self.call(transaction, fee_rule_override: nil, resolve: true)
      new(transaction, fee_rule_override, resolve).call
    end

    def initialize(transaction, override, resolve)
      @transaction = transaction
      @override = override
      @resolve = resolve
    end

    def call
      if !@resolve && @override.nil? && @transaction.applied_base_fee_rate.present?
        recompute_with_snapshot
      else
        fee_rule, status = pick_fee_rule
        apply_rule(fee_rule, status)
      end
    end

    private

    def recompute_with_snapshot
      amount = @transaction.transaction_amount_vnd
      return Result.new(fee_rule: @transaction.fee_rule, fee_status: :not_found) if amount.nil?

      previous = @transaction.calculation_data
      calculation = Calculator.call(transaction_amount_vnd: amount, base_fee_rate: @transaction.applied_base_fee_rate,
                                    dealer_rate: @transaction.applied_dealer_rate)
      @transaction.assign_attributes(
        amount_after_base_fee_vnd: calculation.amount_after_base_fee_vnd,
        dealer_amount_vnd: calculation.dealer_amount_vnd,
        profit_amount_vnd: calculation.profit_amount_vnd,
        calculation_data: calculation.calculation_data.merge(
          "fee_rule" => previous["fee_rule"],
          "fee_rule_source" => previous["fee_rule_source"] || "resolved",
          "rates_from" => "snapshot",
          "calculated_at" => Time.current.utc.iso8601
        ).compact
      )
      Result.new(fee_rule: @transaction.fee_rule, fee_status: :snapshot)
    end

    def apply_rule(fee_rule, status)
      amount = @transaction.transaction_amount_vnd
      if fee_rule && amount
        calculation = Calculator.call(transaction_amount_vnd: amount, base_fee_rate: fee_rule.base_fee_rate,
                                      dealer_rate: fee_rule.dealer_rate)
        @transaction.assign_attributes(
          fee_rule: fee_rule,
          applied_base_fee_rate: fee_rule.base_fee_rate,
          amount_after_base_fee_vnd: calculation.amount_after_base_fee_vnd,
          applied_dealer_rate: fee_rule.dealer_rate,
          dealer_amount_vnd: calculation.dealer_amount_vnd,
          profit_amount_vnd: calculation.profit_amount_vnd,
          calculation_data: calculation.calculation_data.merge(
            "fee_rule" => AuditLogger.serialize(fee_rule.snapshot_attributes),
            "fee_rule_source" => status.to_s,
            "calculated_at" => Time.current.utc.iso8601
          )
        )
      else
        @transaction.assign_attributes(fee_rule: fee_rule, **self.class.blank_calculation)
      end

      Result.new(fee_rule: fee_rule, fee_status: status)
    end

    def pick_fee_rule
      return [ @override, :override ] if @override

      result = FeeRules::Resolver.call(
        merchant: @transaction.merchant, dealer: @transaction.dealer,
        card_type: @transaction.card_type, at: @transaction.transaction_at
      )
      [ result.fee_rule, result.status ]
    end
  end
end
