module FixtureHelpers
  def bill_fixture_path(name)
    Rails.root.join("spec/fixtures/bills", name)
  end

  def extraction_fixture(name)
    JSON.parse(Rails.root.join("spec/fixtures/extractions", "#{name}.json").read)
  end

  def telegram_fixture(name)
    JSON.parse(Rails.root.join("spec/fixtures/telegram", "#{name}.json").read)
  end

  # A fake vision provider returning a fixture, so no paid API is ever called.
  def stub_vision(data, provider: "openai", model: "gpt-test")
    result = BillVision::Result.new(provider: provider, model: model, data: data, raw: { "fixture" => true, "data" => data })
    allow(BillVision::Extractor).to receive(:call).and_return(result)
    result
  end

  # Normalized document as stored on BillImage, for builder/evaluator specs.
  def normalized_document(overrides = {})
    BillVision::Normalizer.call({ "documents" => [ extraction_fixture("normal_settlement")["documents"].first.merge(overrides) ] },
                                provider: "openai", model: "gpt-test")["documents"].first
  end
end

RSpec.configure do |config|
  config.include FixtureHelpers
end
