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

  it "validates a bounded model-estimated score while accepting older assessments without a score" do
    assessment = { "status" => "no_visible_signs", "evidence" => [], "risk_score" => 0.15 }
    expect(described_class.valid?(assessment)).to be(true)
    expect(described_class.valid?(assessment.merge("risk_score" => nil))).to be(true)
    [ -0.01, 1.01, "0.5", Float::NAN, Float::INFINITY ].each do |invalid|
      expect(described_class.valid?(assessment.merge("risk_score" => invalid))).to be(false)
    end
  end

  it "keeps uncertainty advisory and excludes outgoing image screening reasons" do
    expect(described_class.blocking_reasons(%w[image_tampering_suspected image_integrity_uncertain model_disagreement])).to eq([ "model_disagreement" ])
  end

  it "does not manufacture a score for an old suspicious assessment from a newer clean read" do
    old = { "status" => "suspicious", "evidence" => [ "Pasted region" ] }
    clean = { "status" => "no_visible_signs", "evidence" => [], "risk_score" => 0.01 }
    expect(described_class.combine([ old, clean ])).to include("status" => "suspicious", "risk_score" => nil)
  end
end
