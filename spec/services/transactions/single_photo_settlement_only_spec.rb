require "rails_helper"

# Outside an album only a settlement becomes a transaction, whatever the
# remitter feature flag: transfers belong to RemitterTransfer, unreadable
# photos and child receipts are skipped instead of cluttering the review queue.
RSpec.describe Transactions::Builder, "single photos" do
  include_context "accounting setup"

  it "builds a settlement" do
    expect(described_class.call(bill_image: analyzed_bill)).to be_one
  end

  it "skips a transfer, an unreadable photo and an uncertain child receipt with the flag on" do
    expect(AppConfig.remitter_features_enabled?).to be(true) # spec default

    unknown = BillVision::Normalizer.call({ "documents" => [] }, provider: "openai", model: "gpt-test")
    unreadable = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                     normalized_extraction: unknown, ocr_status: "needs_review")
    child = extraction_fixture("child_receipt").tap { |data| data["documents"][0]["confidence"]["total_amount_vnd"] = 0.4 }
    uncertain_child = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                          normalized_extraction: BillVision::Normalizer.call(child, provider: "openai", model: "gpt-test"),
                                          ocr_status: "needs_review")

    expect(described_class.call(bill_image: analyzed_bill(extraction: "transfer"))).to be_empty
    expect(described_class.call(bill_image: unreadable)).to be_empty
    expect(described_class.call(bill_image: uncertain_child)).to be_empty
    expect(Transaction.count).to eq(0)
  end

  it "still sends a photo whose OCR went wrong to review, even when it reads as unknown" do
    %w[malformed_primary_extraction primary_output_truncated primary_refused validation_budget_exhausted
       validator_failed].each do |reason|
      normalized = BillVision::Normalizer.call({ "documents" => [] }, provider: "openai", model: "gpt-test")
      normalized["documents"].each { |doc| doc["vision_review_reasons"] = [ reason ] }
      bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                       normalized_extraction: normalized, ocr_status: "needs_review")

      transaction = described_class.call(bill_image: bill_image).sole
      expect(transaction).to be_needs_review
      expect(transaction.review_reason_codes).to include(reason)
    end
  end

  it "always builds a photo uploaded by hand in the admin, so the uploader sees a result" do
    unknown = BillVision::Normalizer.call({ "documents" => [] }, provider: "openai", model: "gpt-test")
    upload = create(:bill_image, telegram_message: nil, source: "manual_upload",
                                 normalized_extraction: unknown, ocr_status: "needs_review")

    expect(described_class.call(bill_image: upload).sole).to be_needs_review
  end

  it "still surfaces an OCR error as a failed transaction" do
    bill_image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat), ocr_status: "failed")

    expect(described_class.call(bill_image: bill_image).sole).to be_failed
  end
end
