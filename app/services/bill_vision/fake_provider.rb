module BillVision
  # Offline provider for development and demos (OCR provider "fake" in settings).
  # Returns the JSON in fixture_path if given, otherwise an unreadable result
  # that always lands in manual review. Never used in production.
  class FakeProvider < BaseProvider
    def initialize(fixture_path: nil)
      raise PermanentError, "The fake vision provider is disabled in production" if Rails.env.production?

      @fixture_path = fixture_path
    end

    def name
      "fake"
    end

    def model
      "fixture"
    end

    def extract(_image)
      data = @fixture_path.present? ? JSON.parse(File.read(@fixture_path)) : unreadable
      Result.new(provider: name, model: model, data: data, raw: { "fixture" => @fixture_path, "data" => data })
    end

    private

    def unreadable
      confidence = Prompt::FIELDS.index_with { 0.0 }
      {
        "documents" => [ Prompt::FIELDS.index_with { nil }.merge("document_type" => "unknown", "confidence" => confidence) ],
        "notes" => "fake provider: no fixture configured"
      }
    end
  end
end
