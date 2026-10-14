require "rails_helper"

RSpec.describe RemitterTransfers::CodeResolver do
  before { Workbook::Seed.call }
  let(:documents) { [ { "document_type" => "transfer", "transfer_memo" => "As02", "transfer_memo_confidence" => 0.99 } ] }
  let(:image) { instance_double(BillImage, documents: documents) }

  def resolve(caption = nil) = described_class.call(caption: caption, image: image)

  it "finds As02 printed in the bank memo with an empty Telegram caption and keeps the configured AS2 spelling" do
    MerchantDealer.find_by!(transfer_code: "AS02").update!(transfer_code: "AS2")
    expect(resolve).to have_attributes(code: "AS2", source: "image", issue: nil)
  end

  it "accepts equivalent caption and image codes regardless of padding or spaces" do
    expect(resolve("as 0002")).to have_attributes(code: "AS02", source: "caption", issue: nil)
  end

  it "refuses conflicting caption and image codes" do
    expect(resolve("TK01")).to have_attributes(code: nil, source: nil, issue: "code_conflict")
    expect(resolve("AS99")).to have_attributes(code: nil, source: nil, issue: "code_conflict")
  end

  it "keeps multiple codes ambiguous even when one source is unambiguous" do
    expect(resolve("AS02 TK01").issue).to eq("code_ambiguous")
    documents.first["transfer_memo"] = "AS02 TK01"
    expect(resolve("AS02").issue).to eq("code_ambiguous")
  end

  it "keeps a low-confidence code as a suggestion but requires human review" do
    documents.first["transfer_memo_confidence"] = 0.6
    expect(resolve).to have_attributes(code: "AS02", source: "image", issue: "code_low_confidence")
  end

  it "does not auto-approve an image code after model disagreement" do
    documents.first["vision_review_reasons"] = [ "model_disagreement" ]
    expect(resolve.issue).to eq("code_ocr_disagreement")
  end

  it "does not look in recipient names, account numbers, settlement text or generic notes" do
    documents.first.merge!("document_type" => "settlement", "recipient_name" => "AS02")
    expect(resolve.issue).to eq("code_missing")
    documents.first.merge!("document_type" => "transfer", "transfer_memo" => nil,
                           "terminal_or_merchant_id" => "AS02")
    expect(resolve.issue).to eq("code_missing")
  end

  it "requires a distinct memo token and does not match a substring or a different numeric code" do
    %w[ZALOAS02 AS020 AS02ABC].each do |memo|
      documents.first["transfer_memo"] = memo
      expect(resolve.issue).to eq("code_missing")
    end
  end
end
