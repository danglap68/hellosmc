FactoryBot.define do
  factory :bill_image do
    telegram_message
    source { "telegram" }
    sequence(:sha256) { |n| Digest::SHA256.hexdigest("bill-#{n}") }
    mime_type { "image/jpeg" }
    file_size { 1000 }
    ocr_status { "pending" }

    after(:build) do |bill_image|
      bill_image.image.attach(
        io: File.open(Rails.root.join("spec/fixtures/bills/normal_settlement.jpg")),
        filename: "bill.jpg", content_type: "image/jpeg"
      )
    end

    # A bill image whose OCR already ran with the given extraction fixture.
    trait :analyzed do
      transient do
        extraction { "normal_settlement" }
      end

      after(:build) do |bill_image, evaluator|
        data = JSON.parse(Rails.root.join("spec/fixtures/extractions/#{evaluator.extraction}.json").read)
        normalized = BillVision::Normalizer.call(data, provider: "openai", model: "gpt-test")
        bill_image.raw_extraction = { "fixture" => evaluator.extraction }
        bill_image.normalized_extraction = normalized
        bill_image.ocr_status = normalized["requires_review"] ? "needs_review" : "completed"
        bill_image.ocr_provider = "openai"
        bill_image.ocr_model = "gpt-test"
      end
    end
  end
end
