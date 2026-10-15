require "rails_helper"

RSpec.describe RemitterTransfers::Builder do
  let(:chat) { create(:telegram_chat, active: true) }
  # Workbook::Seed already creates Lập (excel_key LẬP, unique): reuse it.
  let(:lap) { Remitter.find_by!(excel_key: "LẬP").tap { |remitter| remitter.update!(telegram_user_id: 777) } }

  before { Workbook::Seed.call }

  # A transfer photo: only the amount matters.
  def transfer_with(caption: "Lap chuyen tien TK01", amount: 29_274_000, confidence: 0.96, document_type: "transfer",
                    sent_at: Time.current)
    data = extraction_fixture("transfer")
    data["documents"][0].merge!("total_amount_vnd" => amount, "document_type" => document_type,
                                "transaction_date" => nil, "transaction_time" => nil)
    data["documents"][0]["confidence"]["total_amount_vnd"] = confidence
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    message = create(:telegram_message, telegram_chat: chat, message_text: caption, telegram_sender_id: 777, sent_at: sent_at)
    create(:bill_image, telegram_message: message, normalized_extraction: normalized, ocr_status: "completed")
    create(:remitter_transfer, telegram_message: message, remitter: lap, transferred_at: sent_at)
  end

  it "approves Lập's 29.274.000 transfer with TK01 and queues the sheet write" do
    transfer = described_class.call(remitter_transfer: transfer_with)

    expect(transfer).to be_approved
    expect(transfer.review_reasons).to be_empty
    expect(transfer.amount_vnd).to eq(29_274_000)
    expect(transfer.transfer_code).to eq("TK01")
    expect(transfer.code_source).to eq("caption")
    expect(transfer.merchant.code).to eq("001")
    expect(transfer.dealer.name).to eq("Chương")
    expect(transfer.merchant_dealer.tid_key).to eq("tid1")
    expect(transfer.bill_image).to be_present
    expect(WriteRemitterReportJob).to have_been_enqueued.with(transfer.id)
    expect(Transaction.count).to eq(0)
  end

  it "approves a 79.197.000 transfer from the visible As02 memo without any caption, then flags another copy" do
    link = MerchantDealer.find_by!(transfer_code: "AS02")
    link.update!(transfer_code: "AS2")
    transfer = transfer_with(caption: nil, amount: 79_197_000)
    image = transfer.telegram_message.bill_images.sole
    extraction = image.normalized_extraction.deep_dup
    extraction["documents"].first.merge!("transfer_memo" => "As02", "transfer_memo_confidence" => 0.99)
    image.update!(normalized_extraction: extraction)

    described_class.call(remitter_transfer: transfer)
    expect(transfer.reload).to be_approved
    expect(transfer).to have_attributes(transfer_code: "AS2", code_source: "image", amount_vnd: 79_197_000,
                                      merchant_dealer: link, dealer: link.dealer)
    expect(WriteRemitterReportJob).to have_been_enqueued.with(transfer.id)

    duplicate = transfer_with(caption: nil, amount: 79_197_000, sent_at: 1.minute.from_now)
    duplicate.telegram_message.bill_images.sole.update!(normalized_extraction: extraction)
    described_class.call(remitter_transfer: duplicate)
    expect(duplicate).to be_needs_review
    expect(duplicate.review_reasons).to include("possible_duplicate")
  end

  it "needs a person below 92% amount confidence" do
    transfer = described_class.call(remitter_transfer: transfer_with(confidence: 0.9))

    expect(transfer).to be_needs_review
    expect(transfer.review_reasons).to eq([ "amount_low_confidence" ])
    expect(WriteRemitterReportJob).not_to have_been_enqueued
  end

  it "ignores image-integrity screening for outgoing transfers while retaining the normal payment checks" do
    transfer = transfer_with
    image = transfer.telegram_message.bill_images.sole
    data = extraction_fixture("transfer")
    data["documents"].first["image_integrity"] = { "status" => "suspicious", "evidence" => [ "Amount line has pasted digits" ] }
    image.update!(normalized_extraction: BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test"))
    described_class.call(remitter_transfer: transfer)
    expect(transfer.reload).to be_approved
    expect(transfer.review_reasons).to be_empty
    expect(WriteRemitterReportJob).to have_been_enqueued.with(transfer.id)
  end

  it "ignores old outgoing integrity warnings but still blocks an OCR disagreement" do
    transfer = transfer_with
    image = transfer.telegram_message.bill_images.sole
    data = image.normalized_extraction.deep_dup
    data["documents"].first["vision_review_reasons"] = %w[image_integrity_uncertain image_tampering_suspected model_disagreement]
    image.update!(normalized_extraction: data)

    described_class.call(remitter_transfer: transfer)

    expect(transfer.reload).to be_needs_review
    expect(transfer.review_reasons).to include("model_disagreement")
    expect(transfer.review_reasons & BillVision::ImageIntegrity::REVIEW_REASONS).to be_empty
    expect(WriteRemitterReportJob).not_to have_been_enqueued
  end

  it "routes a booked transfer detail with Gt03 to money out even without a success banner" do
    transfer = transfer_with(caption: nil, amount: 26_021_000)
    data = extraction_fixture("transfer")
    data["documents"].first.merge!("shows_success_message" => false, "shows_qr_code" => false,
                                   "shows_booked_transfer" => true, "bank_transaction_reference" => "FT26287703118373",
                                   "recipient_name" => "LE KHAC LAM", "total_amount_vnd" => 26_021_000,
                                   "transaction_date" => "2026-10-14", "transaction_time" => "16:54:02",
                                   "transfer_memo" => "Gt03", "transfer_memo_confidence" => 0.99)
    image = transfer.telegram_message.bill_images.sole
    image.update!(normalized_extraction: BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test"))
    described_class.call(remitter_transfer: transfer)
    expect(transfer.reload).to be_approved
    expect(transfer).to have_attributes(transfer_code: "GT03", code_source: "image", amount_vnd: 26_021_000)
    expect(Transaction.count).to eq(0)
  end

  it "uses the configured code when zero padding is missing, and still detects repeat payments" do
    first = described_class.call(remitter_transfer: transfer_with(caption: "chuyen TK1"))
    expect(first).to be_approved
    expect(first.transfer_code).to eq("TK01")
    second = described_class.call(remitter_transfer: transfer_with(caption: "chuyen TK001", sent_at: first.transferred_at + 2.minutes))
    expect(second).to be_needs_review
    expect(second.transfer_code).to eq("TK01")
    expect(second.review_reasons).to include("possible_duplicate")
  end

  it "does not approve an ambiguous legacy zero-padding configuration" do
    MerchantDealer.find_by!(transfer_code: "TK02").update_column(:transfer_code, "TK1")
    transfer = described_class.call(remitter_transfer: transfer_with(caption: "TK01"))
    expect(transfer).to be_needs_review
    expect(transfer.review_reasons).to include("code_ambiguous")
    expect(WriteRemitterReportJob).not_to have_been_enqueued
  end

  it "still detects a duplicate after the configured code is renamed with different zero padding" do
    first = described_class.call(remitter_transfer: transfer_with(caption: "TK01"))
    MerchantDealer.find_by!(transfer_code: "TK01").update!(transfer_code: "TK1")
    second = described_class.call(remitter_transfer: transfer_with(caption: "TK001", sent_at: first.transferred_at + 2.minutes))
    expect(second.transfer_code).to eq("TK1")
    expect(second).to be_needs_review
    expect(second.review_reasons).to include("possible_duplicate")
  end

  it "does not care about the receipt's date or recipient" do
    transfer = described_class.call(remitter_transfer: transfer_with)

    expect(transfer).to be_approved
  end

  describe "a photo that is not a bank transfer" do
    it "is skipped: rejected with a reason, the message ignored, nothing written" do
      transfer = described_class.call(remitter_transfer: transfer_with(document_type: "unknown"))

      expect(transfer).to be_rejected
      expect(transfer.review_reasons).to eq([ "not_a_transfer" ])
      expect(transfer.telegram_message.reload.processing_status).to eq("ignored")
      expect(WriteRemitterReportJob).not_to have_been_enqueued
      expect(AuditLog.where(auditable: transfer, action: "remitter_transfer.evaluated")).to exist
    end

    it "reviews conflicting QR and success readings without rejecting or writing the bill" do
      transfer = transfer_with
      data = extraction_fixture("transfer")
      data["documents"][0].merge!("shows_qr_code" => true, "shows_success_message" => true)
      normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
      transfer.telegram_message.bill_images.first.update!(normalized_extraction: normalized)

      expect(described_class.call(remitter_transfer: transfer)).to be_needs_review
      expect(transfer.review_reasons).to include("transfer_confirmation_conflict")
      expect(transfer.amount_vnd).to eq(600_000_000)
      expect(transfer.telegram_message.reload.processing_status).to eq("processed")
      expect(WriteRemitterReportJob).not_to have_been_enqueued
    end

    it "still rejects a payment-request QR without a success reading" do
      transfer = transfer_with
      data = extraction_fixture("transfer")
      data["documents"][0].merge!("shows_qr_code" => true, "shows_success_message" => false)
      transfer.telegram_message.bill_images.first.update!(
        normalized_extraction: BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
      )
      expect(described_class.call(remitter_transfer: transfer)).to be_rejected
      expect(WriteRemitterReportJob).not_to have_been_enqueued
    end

    it "is skipped when the slip does not say the transfer succeeded" do
      transfer = transfer_with
      data = extraction_fixture("transfer")
      data["documents"][0].merge!("shows_qr_code" => false, "shows_success_message" => false)
      normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
      transfer.telegram_message.bill_images.first.update!(normalized_extraction: normalized)

      expect(described_class.call(remitter_transfer: transfer)).to be_rejected
    end

    it "is skipped when it is a sale slip" do
      expect(described_class.call(remitter_transfer: transfer_with(document_type: "child_receipt"))).to be_rejected
    end

    it "is skipped when OCR found no receipt at all (a calculator)" do
      transfer = transfer_with
      empty = BillVision::Normalizer.call({ "documents" => [] }, provider: "openai", model: "gpt-test")
      transfer.telegram_message.bill_images.first.update!(normalized_extraction: empty)

      expect(described_class.call(remitter_transfer: transfer)).to be_rejected
    end

    it "never rejects or approves uncertain OCR even with a valid caption and high amount confidence" do
      transfer = transfer_with(document_type: "unknown")
      normalized = transfer.telegram_message.bill_images.first.normalized_extraction
      normalized["documents"][0]["vision_review_reasons"] = [ "primary_output_truncated", "model_disagreement" ]
      transfer.telegram_message.bill_images.first.update!(normalized_extraction: normalized, ocr_status: "needs_review")

      expect(described_class.call(remitter_transfer: transfer)).to be_needs_review
      expect(transfer.transfer_code).to eq("TK01")
      expect(transfer.review_reasons).to include("primary_output_truncated", "model_disagreement")
      expect(WriteRemitterReportJob).not_to have_been_enqueued
    end

    it "keeps model disagreement on a transfer even when its caption supplies the code" do
      transfer = transfer_with
      image = transfer.telegram_message.bill_images.sole
      normalized = image.normalized_extraction.deep_dup
      normalized["documents"].first["vision_review_reasons"] = [ "model_disagreement" ]
      image.update!(normalized_extraction: normalized, ocr_status: "needs_review")

      expect(described_class.call(remitter_transfer: transfer)).to be_needs_review
      expect(transfer.review_reasons).to eq([ "model_disagreement" ])
      expect(WriteRemitterReportJob).not_to have_been_enqueued
    end

    it "is not skipped while OCR has not finished" do
      transfer = transfer_with(document_type: "unknown")
      transfer.telegram_message.bill_images.first.update!(ocr_status: "pending")

      expect(described_class.call(remitter_transfer: transfer)).to be_processing
    end

    it "stays skipped when the caption is edited later" do
      transfer = described_class.call(remitter_transfer: transfer_with(document_type: "unknown"))
      transfer.telegram_message.update!(message_text: "Lap chuyen tien TK02")

      expect(described_class.call(remitter_transfer: transfer.reload)).to be_rejected
    end
  end

  it "reports a missing, ambiguous or unmapped code" do
    expect(described_class.call(remitter_transfer: transfer_with(caption: "chuyen tien")).review_reasons)
      .to eq([ "code_missing" ])
    expect(described_class.call(remitter_transfer: transfer_with(caption: "TK01 GT02")).review_reasons)
      .to eq([ "code_ambiguous" ])

    MerchantDealer.find_by!(tid_key: "tid2", merchant: Merchant.find_by!(code: "GTD001")).update!(active: false)
    expect(described_class.call(remitter_transfer: transfer_with(caption: "GT02")).review_reasons)
      .to eq([ "code_dealer_inactive" ])
  end

  it "needs a person to pick the remitter when the sender is unknown" do
    transfer = transfer_with
    transfer.update!(remitter: nil)

    expect(described_class.call(remitter_transfer: transfer).review_reasons).to eq([ "remitter_unknown" ])
  end

  it "reports an unreadable amount" do
    transfer = described_class.call(remitter_transfer: transfer_with(amount: nil))

    expect(transfer.review_reasons).to include("amount_missing")
  end

  it "flags the same remitter, code and amount twice within the duplicate window" do
    first = described_class.call(remitter_transfer: transfer_with)
    second = described_class.call(remitter_transfer: transfer_with(sent_at: first.transferred_at + 2.minutes))

    expect(second).to be_needs_review
    expect(second.review_reasons).to eq([ "possible_duplicate" ])
    expect(second.metadata.dig("duplicate_check", "matches"))
      .to eq([ { "id" => first.id, "reasons" => [ "same_payment_details" ] } ])
  end

  it "fails when the photo could not be read" do
    transfer = transfer_with
    transfer.bill_image_id = nil
    transfer.telegram_message.bill_images.first.update!(ocr_status: "failed")

    expect(described_class.call(remitter_transfer: transfer)).to be_failed
  end

  it "waits while the photo is still being read" do
    transfer = transfer_with
    transfer.telegram_message.bill_images.first.update!(ocr_status: "processing")

    expect(described_class.call(remitter_transfer: transfer.reload)).to be_processing
  end

  it "leaves a transfer that is written or decided by a person alone" do
    transfer = transfer_with
    transfer.update!(status: "approved", written_at: Time.current, transfer_code: "TK01")

    described_class.call(remitter_transfer: transfer)
    expect(transfer.reload.review_reasons).to eq([])
    expect(WriteRemitterReportJob).not_to have_been_enqueued
  end
end
