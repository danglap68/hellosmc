module Transactions
  # Deterministic accounting calculation. BigDecimal in, whole VND out.
  # Rounding: half-up to the nearest đồng, applied once per output amount.
  #
  #   amount_after_base_fee = transaction_amount * (1 - base_fee_rate)
  #   dealer_amount         = transaction_amount * (1 - dealer_rate)      (when a dealer rate is configured)
  #   profit                = amount_after_base_fee - dealer_amount
  class Calculator
    class InvalidInput < ArgumentError; end

    ROUNDING = :half_up
    BASE_FORMULA = "transaction_amount * (1 - base_fee_rate)".freeze
    DEALER_FORMULA = "transaction_amount * (1 - dealer_rate)".freeze
    PROFIT_FORMULA = "amount_after_base_fee - dealer_amount".freeze

    Result = Data.define(:amount_after_base_fee_vnd, :dealer_amount_vnd, :profit_amount_vnd, :calculation_data)

    def self.call(transaction_amount_vnd:, base_fee_rate:, dealer_rate: nil)
      new(transaction_amount_vnd:, base_fee_rate:, dealer_rate:).call
    end

    def initialize(transaction_amount_vnd:, base_fee_rate:, dealer_rate: nil)
      @amount = validate_amount(transaction_amount_vnd)
      @base_fee_rate = validate_rate(base_fee_rate, "base_fee_rate")
      @dealer_rate = dealer_rate.nil? ? nil : validate_rate(dealer_rate, "dealer_rate")
    end

    def call
      after_base_fee = apply(@base_fee_rate)
      dealer_amount = @dealer_rate && apply(@dealer_rate)
      profit = dealer_amount && (after_base_fee - dealer_amount)

      data = {
        "formula" => BASE_FORMULA,
        "rounding" => "half_up_to_integer_vnd",
        "transaction_amount_vnd" => @amount,
        "base_fee_rate" => @base_fee_rate.to_s("F"),
        "amount_after_base_fee_vnd" => after_base_fee
      }
      if @dealer_rate
        data.merge!(
          "dealer_formula" => DEALER_FORMULA,
          "dealer_rate" => @dealer_rate.to_s("F"),
          "dealer_amount_vnd" => dealer_amount,
          "profit_formula" => PROFIT_FORMULA,
          "profit_amount_vnd" => profit
        )
      end

      Result.new(amount_after_base_fee_vnd: after_base_fee, dealer_amount_vnd: dealer_amount,
                 profit_amount_vnd: profit, calculation_data: data)
    end

    private

    def apply(rate)
      (BigDecimal(@amount) * (BigDecimal("1") - rate)).round(0, ROUNDING).to_i
    end

    def validate_amount(value)
      raise InvalidInput, "transaction_amount_vnd must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      value
    end

    def validate_rate(value, name)
      raise InvalidInput, "#{name} must not be a Float" if value.is_a?(Float)

      rate = BigDecimal(value.to_s)
      raise InvalidInput, "#{name} must be within [0, 1)" unless rate >= 0 && rate < 1

      rate
    rescue ArgumentError, TypeError
      raise InvalidInput, "#{name} is not a decimal"
    end
  end
end
