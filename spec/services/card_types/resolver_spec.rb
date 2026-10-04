require "rails_helper"

RSpec.describe CardTypes::Resolver do
  let!(:normal) { create(:normal_card_type) }
  let!(:mb) { create(:mb_card_type) }
  let!(:napas) { create(:napas_card_type) }
  let(:dealer) { create(:dealer) }
  let(:merchant) { create(:merchant, dealer: dealer) }

  it "prefers the explicit Telegram tag over defaults" do
    merchant.update!(default_card_type: napas)
    result = described_class.call(message_text: "MB", merchant: merchant, dealer: dealer)
    expect(result.card_type).to eq(mb)
    expect(result.source).to eq("message_tag")
  end

  it "falls back to merchant default, then dealer default, then normal" do
    merchant.update!(default_card_type: napas)
    dealer.update!(default_card_type: mb)
    expect(described_class.call(message_text: nil, merchant: merchant, dealer: dealer).card_type).to eq(napas)

    merchant.update!(default_card_type: nil)
    expect(described_class.call(message_text: nil, merchant: merchant, dealer: dealer).card_type).to eq(mb)

    dealer.update!(default_card_type: nil)
    result = described_class.call(message_text: nil, merchant: merchant, dealer: dealer)
    expect(result.card_type).to eq(normal)
    expect(result.source).to eq("system_default")
  end

  it "flags conflicting tags instead of choosing" do
    result = described_class.call(message_text: "MB Napas", merchant: merchant, dealer: dealer)
    expect(result.card_type).to be_nil
    expect(result.issue).to eq("card_type_conflict")
  end
end
