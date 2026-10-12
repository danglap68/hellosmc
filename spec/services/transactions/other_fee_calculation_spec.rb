require "rails_helper"

# Sales with another fee calculation are not booked: SmartPOS visible in the photo, or an
# HKD with "Bỏ qua bill" on. They stay as an excluded row with a tag, so a person can find
# and book them later.
RSpec.describe Transactions::Builder, "other fee calculation" do
  include_context "accounting setup"

  def bill_with(source: "telegram", **changes)
    data = extraction_fixture("normal_settlement")
    data["documents"].each { |doc| doc.merge!(changes.transform_keys(&:to_s)) }
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    create(:bill_image, telegram_message: source == "telegram" ? create(:telegram_message, telegram_chat: chat) : nil,
                        source: source, normalized_extraction: normalized, ocr_status: "completed")
  end

  def skip_thien_kim!
    Merchant.where("normalized_name LIKE '%thien kim%'").first!.update!(skip_bills: true)
  end

  it "books an ordinary settlement" do
    transaction = described_class.call(bill_image: bill_with(shows_smart_pos: false)).sole
    expect(transaction.tags).to be_empty
    expect(transaction.status).to be_in(%w[approved needs_review])
  end

  it "keeps a SmartPOS photo as an excluded row with what the bill says, and nothing calculated" do
    bill = bill_with(shows_smart_pos: true)

    transaction = described_class.call(bill_image: bill).sole

    expect(transaction).to be_excluded
    expect(transaction.tags).to eq([ "smart_pos" ])
    expect(transaction.transaction_amount_vnd).to be_positive
    expect(transaction.transaction_at).to be_present
    expect(transaction.merchant).to be_present
    expect([ transaction.dealer, transaction.card_type, transaction.fee_rule, transaction.amount_after_base_fee_vnd ]).to all(be_nil)
    expect(transaction.reviews).to be_empty
    expect(transaction.source_data["excluded_reason"]).to eq("smart_pos")
    expect(AuditLog.where(auditable: transaction, action: "transaction.created")).to exist
  end

  it "tags an HKD with 'Bỏ qua bill' on, by exact or near name" do
    skip_thien_kim!

    [ "HỘ KINH DOANH THIÊN KIM GV-1", "HKD THIÊN KIM GV 2" ].each do |name|
      transaction = described_class.call(bill_image: bill_with(merchant_name: name,
                                                               transaction_time: "10:#{rand(10..59)}:00")).sole
      expect(transaction).to be_excluded
      expect(transaction.tags).to eq([ "skip_merchant" ])
    end
  end

  it "does not book the same photo twice when OCR runs again" do
    bill = bill_with(shows_smart_pos: true)

    described_class.call(bill_image: bill)
    described_class.call(bill_image: bill)

    expect(Transaction.where(bill_image: bill).count).to eq(1)
  end

  it "still builds a photo uploaded by hand, which a person chose" do
    expect(described_class.call(bill_image: bill_with(source: "manual_upload", shows_smart_pos: true)).sole.tags).to be_empty
  end

  it "is not queued for review, written to the sheet or counted as a possible duplicate" do
    bill = bill_with(shows_smart_pos: true)
    expect { described_class.call(bill_image: bill) }.not_to have_enqueued_job(WriteHelloSmcWorkbookJob)

    twin = bill_with(shows_smart_pos: true, lot_number: "999999")
    described_class.call(bill_image: twin)
    expect(Transaction.review_queue).to be_empty
    expect(Transaction.where(status: "excluded").count).to eq(2)
  end

  describe Transactions::Includer do
    it "books an excluded bill like any other and does not exclude it again" do
      bill = bill_with(shows_smart_pos: true)
      transaction = Transactions::Builder.call(bill_image: bill).sole
      actor = create(:user, :admin)

      expect(described_class.call(transaction: transaction, actor: actor)).to be(true)

      transaction.reload
      expect(transaction).not_to be_excluded
      expect(transaction.tags).to be_empty
      expect(transaction.dealer).to be_present
      expect(AuditLog.where(auditable: transaction, action: "transaction.included")).to exist
      expect(Transaction.where(bill_image: bill).count).to eq(1)

      # a later OCR rerun leaves the booked row alone and does not exclude it again
      Transactions::Builder.call(bill_image: bill)
      expect(transaction.reload).not_to be_excluded
    end

    it "refuses a transaction that is not excluded" do
      transaction = Transactions::Builder.call(bill_image: bill_with).sole

      expect(described_class.call(transaction: transaction)).to be(false)
      expect(transaction.reload.status).to be_in(%w[approved needs_review])
    end
  end
end
