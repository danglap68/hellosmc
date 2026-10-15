require "rails_helper"

RSpec.describe Merchants::Resolver, "AI catalog matching" do
  let!(:merchant) { create(:merchant, name: "Gat Tan Day Coffe") }

  def document(name:, id: merchant.id, confidence: 0.97, identifier: nil)
    { "merchant_name" => name, "terminal_or_merchant_id" => identifier,
      "merchant_match" => { "merchant_id" => id, "confidence" => confidence } }
  end

  it "uses an AI-only match as a suggestion and never calls it exact or fuzzy enough to approve" do
    result = described_class.for_document(document(name: "GÁT ... 2"))
    expect(result.merchant).to eq(merchant)
    expect(result.method).to eq(:ai_match)
    expect(result).not_to be_exact
    expect(result).not_to be_fuzzy
  end

  it "keeps a corroborated deterministic near match and its original score" do
    doc = document(name: "GÁT TÁN DÂY COFFEE 2")
    baseline = described_class.deterministic_for_document(doc)
    result = described_class.for_document(doc)
    expect(result).to eq(baseline)
    expect(result.merchant).to eq(merchant)
  end

  it "does not let an AI suggestion override a configured identifier" do
    other = create(:merchant, name: "Cherry Coffee")
    create(:merchant_alias, merchant: other, alias_type: "merchant_id", alias: "000123")
    result = described_class.for_document(document(name: "GÁT ... 2", identifier: "000123"))
    expect(result.merchant).to eq(other)
    expect(result.method).to eq(:identifier)
    expect(result.candidates).to contain_exactly(other)
    expect(result).to be_exact
  end

  it "does not trust a conflicting fuzzy result" do
    other = create(:merchant, name: "Cherry Coffee")
    result = described_class.for_document(document(name: "CHERY COFFEE", id: merchant.id))
    expect(result.method).to eq(:ai_conflict)
    expect(result.merchant).to be_nil
    expect(result.candidates).to include(merchant, other)
  end

  it "requires review when confidence is low or the suggested business was deactivated" do
    expect(described_class.for_document(document(name: "GÁT ... 2", confidence: 0.2)).method).to eq(:ai_uncertain)
    merchant.update!(active: false)
    result = described_class.for_document(document(name: "GÁT ... 2"))
    expect(result.method).to eq(:ai_uncertain)
    expect(result.merchant).to be_nil
  end

  it "keeps the existing resolver for legacy and abstaining AI output" do
    doc = document(name: "Gat Tan Day Coffe 2").except("merchant_match")
    expect(described_class.for_document(doc)).to be_exact
    expect(described_class.for_document(doc.merge("merchant_match" => nil))).to be_exact
  end
end
