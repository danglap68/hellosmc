require "rails_helper"

RSpec.describe Transactions::Calculator do
  it "applies the observed formula exactly" do
    result = described_class.call(transaction_amount_vnd: 10_000, base_fee_rate: BigDecimal("0.0088"))
    expect(result.amount_after_base_fee_vnd).to eq(9_912)
  end

  it "computes the 10,000,000 VND example" do
    result = described_class.call(transaction_amount_vnd: 10_000_000, base_fee_rate: "0.0088")
    expect(result.amount_after_base_fee_vnd).to eq(9_912_000)
    expect(result.calculation_data).to include(
      "formula" => "transaction_amount * (1 - base_fee_rate)",
      "transaction_amount_vnd" => 10_000_000,
      "base_fee_rate" => "0.0088",
      "amount_after_base_fee_vnd" => 9_912_000
    )
  end

  it "rounds half up to the nearest đồng" do
    # 11,445,000 * (1 - 0.0121) = 11,306,515.5 -> 11,306,516
    result = described_class.call(transaction_amount_vnd: 11_445_000, base_fee_rate: BigDecimal("0.0121"))
    expect(result.amount_after_base_fee_vnd).to eq(11_306_516)
  end

  it "computes dealer amount and profit when a dealer rate exists" do
    result = described_class.call(transaction_amount_vnd: 10_000_000, base_fee_rate: BigDecimal("0.0088"),
                                  dealer_rate: BigDecimal("0.0121"))
    expect(result.dealer_amount_vnd).to eq(9_879_000)
    expect(result.profit_amount_vnd).to eq(33_000)
    expect(result.calculation_data["dealer_rate"]).to eq("0.0121")
  end

  it "rejects Float rates and non-integer amounts" do
    expect { described_class.call(transaction_amount_vnd: 10_000, base_fee_rate: 0.0088) }
      .to raise_error(described_class::InvalidInput)
    expect { described_class.call(transaction_amount_vnd: 10_000.0, base_fee_rate: "0.0088") }
      .to raise_error(described_class::InvalidInput)
    expect { described_class.call(transaction_amount_vnd: 0, base_fee_rate: "0.0088") }
      .to raise_error(described_class::InvalidInput)
  end

  it "rejects rates outside [0, 1)" do
    expect { described_class.call(transaction_amount_vnd: 10_000, base_fee_rate: "1") }
      .to raise_error(described_class::InvalidInput)
  end
end
