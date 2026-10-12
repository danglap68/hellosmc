require "rails_helper"

# Bills taken out of the accounting flow (SmartPOS, HKD "Bỏ qua bill") are tagged and
# hidden from the transaction list until asked for.
RSpec.describe "Excluded transactions" do
  include_context "accounting setup"

  let(:operator) { create(:user, :operator) }
  let!(:booked) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }
  let!(:skipped) do
    data = extraction_fixture("normal_settlement")
    data["documents"].each { |doc| doc["shows_smart_pos"] = true }
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    bill = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                               normalized_extraction: normalized, ocr_status: "completed")
    Transactions::Builder.call(bill_image: bill).sole
  end

  before { sign_in operator }

  it "hides the tagged bills from the list by default" do
    get admin_transactions_path
    expect(response.body).to include("##{booked.id}</a>")
    expect(response.body).not_to include("##{skipped.id}</a>")
  end

  it "shows them with 'Hiện cả bill đã bỏ qua', by tag, or by the excluded status" do
    [ { show_skipped: "1" }, { tag: "smart_pos" }, { status: "excluded" } ].each do |params|
      get admin_transactions_path(params)
      expect(response.body).to include("##{skipped.id}</a>"), params.inspect
      expect(response.body).to include("SmartPOS")
    end

    get admin_transactions_path(tag: "smart_pos")
    expect(response.body).not_to include("##{booked.id}</a>")
    get admin_transactions_path(tag: "skip_merchant")
    expect(response.body).not_to include("##{skipped.id}</a>")
  end

  it "has no approve or edit action, and an 'Đưa vào xử lý' action on the detail page" do
    get admin_transaction_path(skipped)
    expect(response.body).to include("Đưa vào xử lý", "Bill này được bỏ qua (SmartPOS)")
    expect(response.body).not_to include(approve_admin_transaction_path(skipped))
  end

  it "books it on 'Đưa vào xử lý'" do
    post include_excluded_admin_transaction_path(skipped)

    expect(response).to redirect_to(admin_transaction_path(skipped))
    expect(flash[:notice]).to eq("Đã đưa bill vào xử lý.")
    expect(skipped.reload).not_to be_excluded
    expect(skipped.tags).to be_empty

    get admin_transactions_path
    expect(response.body).to include("##{skipped.id}</a>")
  end

  it "refuses a bill that is not excluded" do
    post include_excluded_admin_transaction_path(booked)

    expect(flash[:alert]).to be_present
    expect(booked.reload).not_to be_excluded
  end

  it "is not counted on the dashboard" do
    stats = Dashboard::Stats.new

    latest = stats.latest_transactions.map(&:id)
    expect(latest).to include(booked.id)
    expect(latest).not_to include(skipped.id)
    expect(stats.processed_today).to eq(Transaction.where.not(status: "excluded").count)

    day = Dashboard::Stats.new(date: skipped.transaction_at.to_date)
    expected = Transaction.where(transaction_at: skipped.transaction_at.all_day)
                          .where.not(status: %w[rejected failed excluded]).sum(:transaction_amount_vnd)
    expect(day.total_amount_today).to eq(expected)
  end

  it "only moves to excluded from processing, and out of it to processing" do
    expect(Transaction.allowed_transition?("processing", "excluded")).to be(true)
    expect(Transaction.allowed_transition?("needs_review", "excluded")).to be(false)
    expect(Transaction.allowed_transition?("approved", "excluded")).to be(false)
    expect(Transaction.allowed_transition?("excluded", "processing")).to be(true)
    expect(Transaction.allowed_transition?("excluded", "approved")).to be(false)
  end
end
