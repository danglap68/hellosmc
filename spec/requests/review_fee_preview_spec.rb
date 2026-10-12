require "rails_helper"

RSpec.describe "Review form fee preview" do
  include_context "accounting setup"

  let(:transaction) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }

  before { sign_in create(:user, :admin) }

  it "gives the page what it needs to recalculate the amounts while the amount is edited" do
    transaction.update!(applied_base_fee_rate: BigDecimal("0.0121"), applied_card_base_fee_rate: nil,
                        applied_dealer_rate: BigDecimal("0.014"), amount_after_base_fee_vnd: 1_000,
                        dealer_amount_vnd: 900, profit_amount_vnd: 100)

    get admin_review_path(transaction)

    expect(response.body).to include(
      %(data-controller="fee-preview"), %(data-fee-preview-base-rate-value="0.0121"),
      %(data-fee-preview-dealer-rate-value="0.014"), %(data-fee-preview-target="amount"),
      %(data-fee-preview-target="afterBaseFee"), %(data-fee-preview-target="dealerAmount"),
      %(data-fee-preview-target="profit")
    )
  end

  it "shows only the base fee amount when there is no agent rate" do
    transaction.update!(applied_base_fee_rate: BigDecimal("0.0121"), applied_card_base_fee_rate: nil,
                        applied_dealer_rate: nil, amount_after_base_fee_vnd: 1_000, dealer_amount_vnd: nil, profit_amount_vnd: nil)

    get admin_review_path(transaction)

    expect(response.body).to include(%(data-fee-preview-target="afterBaseFee"))
    expect(response.body).not_to include(%(data-fee-preview-target="dealerAmount"), %(data-fee-preview-target="profit"))
  end

  it "keeps the server as the source of truth: saving a new amount recalculates every amount" do
    transaction.update!(applied_base_fee_rate: BigDecimal("0.0121"), applied_card_base_fee_rate: nil,
                        applied_dealer_rate: BigDecimal("0.014"))

    result = Transactions::Corrector.call(transaction: transaction, actor: create(:user, :admin),
                                          params: { transaction_amount_vnd: "10.000.000" })

    expect(result).to be_success
    transaction.reload
    expect(transaction.transaction_amount_vnd).to eq(10_000_000)
    expect(transaction.amount_after_base_fee_vnd).to eq(9_879_000)
    expect(transaction.dealer_amount_vnd).to eq(9_860_000)
    expect(transaction.profit_amount_vnd).to eq(19_000)
  end
end
