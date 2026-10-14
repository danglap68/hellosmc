require "rails_helper"

RSpec.describe BillVision::ImageIntegrity do
  it "requires concrete bounded evidence for suspicious assessments and rejects schema drift" do
    good = { "status" => "suspicious", "evidence" => [ "Amount characters overlap a pasted region" ] }
    expect(described_class.valid?(good)).to be(true)
    [ good.merge("evidence" => []), good.merge("evidence" => [ " " ]),
      good.merge("evidence" => [ "x" * 161 ]), good.merge("status" => "genuine"),
      good.merge("probability_ai" => 0.99) ].each do |invalid|
      expect(described_class.valid?(invalid)).to be(false)
    end
    expect(described_class.valid?("status" => "uncertain", "evidence" => [])).to be(true)
    expect(described_class.valid?("status" => "no_visible_signs", "evidence" => [])).to be(true)
  end

  it "keeps old extractions unassessed instead of claiming they passed screening" do
    data = extraction_fixture("normal_settlement")
    data["documents"].sole.delete("image_integrity")
    result = BillVision::Normalizer.call(data, provider: "openai", model: "legacy")
    expect(result["documents"].sole["image_integrity"]).to eq("status" => "not_assessed", "evidence" => [])
  end
end
