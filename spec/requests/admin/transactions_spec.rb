require "rails_helper"

RSpec.describe "Admin transactions" do
  include_context "accounting setup"

  let(:operator) { create(:user, :operator) }
  let!(:transaction) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }

  before { sign_in operator }

  it "filters by status and dealer" do
    get admin_transactions_path(status: "needs_review", dealer_id: dealer.id)
    expect(response.body).to include("##{transaction.id}</a>")

    get admin_transactions_path(status: "approved")
    expect(response.body).not_to include("##{transaction.id}</a>")
  end

  it "approves with audit trail" do
    post approve_admin_transaction_path(transaction)
    expect(transaction.reload).to be_approved
    expect(transaction.approved_by).to eq(operator)
    expect(flash[:notice]).to eq("Đã duyệt giao dịch.")
  end

  it "corrects through the edit form" do
    patch admin_transaction_path(transaction), params: {
      transaction: { transaction_amount_vnd: "12.000.000", transaction_date: "2026-10-04", transaction_time: "10:57:25",
                     merchant_id: merchant.id, dealer_id: dealer.id, card_type_id: normal_card.id }
    }
    expect(response).to redirect_to(admin_transaction_path(transaction))
    expect(transaction.reload.transaction_amount_vnd).to eq(12_000_000)
    expect(transaction.amount_after_base_fee_vnd).to eq(11_894_400)
  end

  it "re-renders the form on invalid input" do
    patch admin_transaction_path(transaction), params: { transaction: { transaction_amount_vnd: "mười triệu" } }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "requests reprocessing" do
    post reprocess_admin_transaction_path(transaction)
    expect(transaction.reload).to be_processing
    expect(AnalyzeBillImageJob).to have_been_enqueued
  end

  it "rejects direct reprocessing requests when the bill has exhausted its lifetime budget" do
    transaction.bill_image.update!(ocr_attempts: 3)
    post reprocess_admin_transaction_path(transaction)
    expect(transaction.reload).to be_needs_review
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
    expect(flash[:alert]).to be_present
  end

  it "keeps legacy extraction readable without new validation metadata" do
    transaction.bill_image.update!(ocr_model: "gpt-4.1")
    get admin_transaction_path(transaction)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("gpt-4.1")
    expect(response.body).not_to include(I18n.t("vision_validation.title"))
  end

  it "shows a concise Vietnamese validation summary with expandable audit data" do
    transaction.bill_image.update!(metadata: { "vision_pipeline" => {
      "primary" => { "model" => "gpt-6-luna", "raw_output" => { "content" => "audit-content" } },
      "validator" => { "model" => "gpt-6.1-sol" }, "validation_triggered" => true,
      "validation_reason" => [ "amount_unreadable" ], "validation_result" => "disagreed"
    } })
    get admin_transaction_path(transaction)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("gpt-6-luna", "gpt-6.1-sol", I18n.t("review_reasons.amount_unreadable"), I18n.t("vision_validation.results.disagreed"))
    audit = Nokogiri::HTML(response.body).at_css("details")
    expect(audit["open"]).to be_nil
    expect(audit.text).to include("audit-content")
  end
end
