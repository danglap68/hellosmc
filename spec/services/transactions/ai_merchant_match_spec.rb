require "rails_helper"

RSpec.describe Transactions::Builder, "AI HKD suggestions" do
  include_context "accounting setup"

  let!(:gat) { create(:merchant, name: "Gat Tan Day Coffe", code: "GTD") }
  let!(:gat_link) { create(:merchant_dealer, merchant: gat, dealer: dealer, tid_key: "tid2") }

  def build_with_match(name: "GÁT ... 2", confidence: 0.97)
    data = extraction_fixture("normal_settlement")
    doc = data["documents"].first
    doc.merge!("merchant_name" => name, "terminal_or_merchant_id" => nil,
               "merchant_match" => { "merchant_id" => gat.id, "confidence" => 0.99 })
    doc["confidence"]["merchant_name"] = confidence
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    image = create(:bill_image, telegram_message: create(:telegram_message, telegram_chat: chat),
                                normalized_extraction: normalized, ocr_status: "completed")
    described_class.call(bill_image: image).sole
  end

  it "assigns the catalog suggestion and configured TID agent, preserving the original OCR name for review" do
    transaction = build_with_match
    expect(transaction.merchant).to eq(gat)
    expect(transaction.dealer).to eq(dealer)
    expect(transaction.raw_merchant_name).to eq("GÁT ... 2")
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("merchant_ai_match")
    expect(transaction.source_data.dig("merchant_resolution", "ai_suggestion")).to eq(
      "merchant_id" => gat.id, "confidence" => 0.99, "name" => gat.name
    )
    expect(WriteHelloSmcWorkbookJob).not_to have_been_enqueued
  end

  it "does not turn high AI match confidence into high OCR confidence or approval" do
    transaction = build_with_match(name: "GÁT TÁN DÂY COFFEE 2", confidence: 0.5)
    expect(transaction.merchant).to eq(gat)
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("merchant_unreadable")
    expect(transaction.extraction.dig("confidence", "merchant_name")).to eq(0.5)
  end

  it "does not exclude a bill solely because AI suggested a business with skip_bills enabled" do
    gat.update!(skip_bills: true)
    expect(build_with_match).to be_needs_review
  end

  it "does not auto-approve when the AI ID contradicts a configured receipt name" do
    transaction = build_with_match(name: "HỘ KINH DOANH THIÊN KIM GV-1")
    expect(transaction.merchant).to eq(merchant)
    expect(transaction).to be_needs_review
    expect(transaction.review_reason_codes).to include("merchant_ai_conflict")
  end

  it "inherits the AI suggestion from the same child receipt as an inherited business name" do
    album = create(:bill_album, telegram_chat: chat)
    child = extraction_fixture("normal_settlement")
    child["documents"].first.merge!("document_type" => "child_receipt", "merchant_name" => "GÁT ... 2",
                                     "merchant_match" => { "merchant_id" => gat.id, "confidence" => 0.99 })
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        normalized_extraction: BillVision::Normalizer.call(child, provider: "openai", model: "gpt-test"),
                        ocr_status: "completed")
    settlement = extraction_fixture("normal_settlement")
    settlement["documents"].first.merge!("merchant_name" => nil, "terminal_or_merchant_id" => nil)
    image = create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                                normalized_extraction: BillVision::Normalizer.call(settlement, provider: "openai", model: "gpt-test"),
                                ocr_status: "completed")
    transaction = described_class.call(bill_image: image).sole
    expect(transaction.merchant).to eq(gat)
    expect(transaction.extraction.dig("merchant_match", "merchant_id")).to eq(gat.id)
    expect(transaction.review_reason_codes).to include("merchant_ai_match")
  end
end
