require "rails_helper"

# A soft date score (between the review and auto-approve thresholds) is not
# reviewed when the date equals the day the bill was posted (or the day before).
RSpec.describe Transactions::Builder, "date corroborated by the send time" do
  include_context "accounting setup"

  # normal_settlement is dated 2026-10-04; "now" is frozen at 2026-10-04 18:00 +07.
  def build_with_date_confidence(score, sent_at:)
    data = extraction_fixture("normal_settlement")
    data["documents"][0]["confidence"]["transaction_date"] = score
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    message = create(:telegram_message, telegram_chat: chat, sent_at: sent_at)
    bill_image = create(:bill_image, telegram_message: message, normalized_extraction: normalized,
                                     ocr_status: normalized["requires_review"] ? "needs_review" : "completed")
    described_class.call(bill_image: bill_image).sole
  end

  it "auto-approves a 0.90 date on a bill posted the same day" do
    transaction = build_with_date_confidence(0.9, sent_at: Time.current)

    expect(transaction.review_reason_codes).not_to include("transaction_date_low_confidence")
    expect(transaction).to be_approved
  end

  it "accepts a bill posted the next morning" do
    transaction = build_with_date_confidence(0.9, sent_at: Time.zone.local(2026, 10, 5, 8, 0, 0))

    expect(transaction.review_reason_codes).not_to include("transaction_date_low_confidence")
  end

  it "still reviews a soft date posted days later" do
    transaction = build_with_date_confidence(0.9, sent_at: Time.zone.local(2026, 10, 8, 9, 0, 0))

    expect(transaction.review_reason_codes).to include("transaction_date_low_confidence")
  end

  it "still reviews an unreadable date even on the same day" do
    transaction = build_with_date_confidence(0.5, sent_at: Time.current)

    expect(transaction.review_reason_codes).to include("transaction_date_unreadable")
  end
end
