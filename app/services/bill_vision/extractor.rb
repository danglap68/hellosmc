module BillVision
  # Vendor-neutral entry point: BillVision::Extractor.call(image:)
  #
  # `image` is a BillImage or a BillVision::Image. The provider (openai |
  # gemini | fake) is an admin setting. Business logic never talks to a
  # provider directly.
  class Extractor
    PROVIDERS = {
      "openai" => "BillVision::OpenaiProvider",
      "gemini" => "BillVision::GeminiProvider",
      "fake" => "BillVision::FakeProvider"
    }.freeze

    def self.call(image:, provider: nil)
      new(provider: provider).call(image: image)
    end

    def self.build_provider(key = AppConfig.vision_provider)
      class_name = PROVIDERS[key.to_s]
      raise PermanentError, "Unknown vision provider: #{key}" unless class_name

      class_name.constantize.new
    end

    def initialize(provider: nil)
      @provider = provider
    end

    def call(image:)
      vision_image = image.is_a?(BillImage) ? Image.from_bill_image(image) : image
      provider.extract(vision_image)
    end

    private

    def provider
      @provider ||= self.class.build_provider
    end
  end
end
