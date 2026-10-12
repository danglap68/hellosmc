require "rails_helper"

# Sales with another fee calculation are not booked here: SmartPOS visible in
# the photo, or an HKD with "Bỏ qua bill" on. Nobody has to look at them.
RSpec.describe Transactions::Builder, "other fee calculation" do
  include_context "accounting setup"

  def bill_with(source: "telegram", **changes)
    data = extraction_fixture("normal_settlement")
    data["documents"].each { |doc| doc.merge!(changes.transform_keys(&:to_s)) }
    normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
    create(:bill_image, telegram_message: source == "telegram" ? create(:telegram_message, telegram_chat: chat) : nil,
                        source: source == "telegram" ? "telegram" : source,
                        normalized_extraction: normalized, ocr_status: "completed")
  end

  it "books an ordinary settlement" do
    expect(described_class.call(bill_image: bill_with(shows_smart_pos: false))).to be_one
  end

  it "skips a photo where SmartPOS is visible (logo on the terminal, screen or slip)" do
    bill = bill_with(shows_smart_pos: true)

    expect(described_class.call(bill_image: bill)).to be_empty
    expect(Transaction.count).to eq(0)
    expect(bill.reload.metadata["skipped_reason"]).to eq("other_fee_calculation")
  end

  it "skips an HKD with 'Bỏ qua bill' on, however OCR spells its name" do
    merchant = Merchant.where("normalized_name LIKE '%thien kim%'").first!
    merchant.update!(skip_bills: true)

    ["HỘ KINH DOANH THIÊN KIM GV-1", "HKD THIÊN KIM GV 2"].each do |name|
      expect(described_class.call(bill_image: bill_with(merchant_name: name))).to be_empty
    end
    expect(Transaction.count).to eq(0)
  end

  it "books the same HKD again once the switch is off" do
    expect(described_class.call(bill_image: bill_with)).to be_one
  end

  it "still builds a photo uploaded by hand, which a person chose" do
    expect(described_class.call(bill_image: bill_with(source: "manual_upload", shows_smart_pos: true))).to be_one
  end
end
