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

  it "puts actual transactions before future OCR dates and unreadable dates in either date direction" do
    older = create(:transaction, transaction_at: 1.day.ago)
    today = create(:transaction, transaction_at: 10.minutes.ago)
    # Includes a legacy row approved despite the bad OCR date, as on production.
    future = create(:transaction, :approved, transaction_at: Time.zone.local(2026, 12, 10, 16, 59, 39))
    undated = create(:transaction, transaction_at: nil)
    snapshot = future.attributes
    ordered_ids = -> { Nokogiri::HTML(response.body).css("tbody tr[data-bulk-id]").map { |row| row["data-bulk-id"].to_i } }

    [ {}, { sort: "when_desc" }, { sort: "invalid" } ].each do |params|
      get admin_transactions_path, params: params
      expect(ordered_ids.call).to eq([ today.id, transaction.id, older.id, future.id, undated.id ])
    end
    get admin_transactions_path(sort: "when_asc")
    expect(ordered_ids.call).to eq([ older.id, transaction.id, today.id, future.id, undated.id ])
    expect(future.reload.attributes).to eq(snapshot)
  end

  it "approves with audit trail" do
    post approve_admin_transaction_path(transaction)
    expect(transaction.reload).to be_approved
    expect(transaction.approved_by).to eq(operator)
    expect(flash[:notice]).to eq("Đã duyệt giao dịch.")
  end

  it "suggests the duplicate reason at every transaction rejection entry point without changing status" do
    transaction.update!(source_data: transaction.source_data.merge("possible_duplicate_ids" => [ 120 ]))
    [ admin_transaction_path(transaction), admin_transactions_path, admin_review_path(transaction) ].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      button = document.at_css('[data-action="rejection#open"]')
      expect(button["type"]).to eq("button")
      expect(button["data-rejection-reason"]).to eq("Trùng với giao dịch #120")
      expect(document.at_css('dialog textarea[name="note"][required]')).to be_present
      expect(document.css("form form")).to be_empty
    end
    expect(transaction.reload).to be_needs_review
  end

  it "suggests the current review warnings when no duplicate is known" do
    get admin_transaction_path(transaction)
    reason = Nokogiri::HTML(response.body).at_css('[data-action="rejection#open"]')["data-rejection-reason"]
    expect(reason).to include(I18n.t("review_reasons.amount_unreadable"))
  end

  it "saves the edited rejection reason with its reviewer and audit trail and displays it" do
    reason = "Trùng với giao dịch #120, đã kiểm tra ảnh gốc"
    post reject_admin_transaction_path(transaction), params: { note: "  #{reason}  " }
    expect(transaction.reload).to be_rejected
    review = transaction.reviews.recent_first.first
    expect(review).to be_rejected
    expect(review.note).to eq(reason)
    expect(review.reviewed_by).to eq(operator)
    expect(AuditLog.find_by!(auditable: transaction, action: "transaction.rejected").metadata["note"]).to eq(reason)
    get admin_transaction_path(transaction)
    expect(Nokogiri::HTML(response.body).at_css(".alert-danger").text).to include(reason)
  end

  it "requires a nonblank reason before rejecting, with no review or audit changes" do
    review = transaction.open_review
    original_review = review.attributes
    post reject_admin_transaction_path(transaction), params: { note: " \n " }
    expect(transaction.reload).to be_needs_review
    expect(review.reload.attributes).to eq(original_review)
    expect(AuditLog.where(auditable: transaction, action: "transaction.rejected")).not_to exist
    expect(flash[:alert]).to include(I18n.t("transactions.rejection.required"))
  end

  it "rejects from the review queue using the supplied reason without applying accounting edits" do
    original_amount = transaction.transaction_amount_vnd
    patch admin_review_path(transaction), params: { decision: "reject", note: "Bill không hợp lệ",
                                                  transaction: { transaction_amount_vnd: "1" } }
    expect(response).to have_http_status(:redirect)
    expect(transaction.reload).to be_rejected
    expect(transaction.transaction_amount_vnd).to eq(original_amount)
    expect(transaction.reviews.recent_first.first.note).to eq("Bill không hợp lệ")
  end

  it "shows validation errors when rejecting from the review queue without a reason" do
    patch admin_review_path(transaction), params: { decision: "reject", note: "" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(transaction.reload).to be_needs_review
    expect(response.body).to include(I18n.t("transactions.rejection.required"))
  end

  it "does not allow a viewer to reject a transaction or see the rejection trigger" do
    sign_in create(:user, :viewer)
    get admin_transaction_path(transaction)
    expect(Nokogiri::HTML(response.body).css('[data-action="rejection#open"]')).to be_empty
    post reject_admin_transaction_path(transaction), params: { note: "Trùng bill" }
    expect(response).to have_http_status(:forbidden)
    expect(transaction.reload).to be_needs_review
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

  it "shows the catalog suggestion next to the original OCR name" do
    transaction.update!(source_data: transaction.source_data.deep_merge(
      "merchant_resolution" => { "ai_suggestion" => { "merchant_id" => merchant.id, "name" => merchant.name, "confidence" => 0.96 } }
    ))
    get admin_transaction_path(transaction)
    expect(response.body).to include("AI đối chiếu: #{merchant.name} · 96%", transaction.raw_merchant_name)
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
