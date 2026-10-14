module BillVision
  # Visual risk screening only. A clean assessment never authenticates a bill
  # or establishes that money moved; suspicious/uncertain results need a human.
  module ImageIntegrity
    STATUSES = %w[no_visible_signs suspicious uncertain].freeze
    REVIEW_REASONS = %w[image_tampering_suspected image_integrity_uncertain].freeze
    SCHEMA = {
      type: "object", additionalProperties: false, required: %w[status evidence],
      properties: {
        status: { type: "string", enum: STATUSES },
        evidence: { type: "array", maxItems: 2, items: { type: "string", maxLength: 160 } }
      }
    }.freeze

    module_function

    def valid?(assessment)
      return false unless assessment.is_a?(Hash) && assessment.keys.sort == %w[evidence status]
      return false unless STATUSES.include?(assessment["status"])

      evidence = assessment["evidence"]
      evidence.is_a?(Array) && evidence.size <= 2 &&
        evidence.all? { |item| item.is_a?(String) && item.strip.present? && item.length <= 160 } &&
        (assessment["status"] != "suspicious" || evidence.any?)
    end

    def reason(assessment)
      case assessment&.dig("status")
      when "suspicious" then "image_tampering_suspected"
      when "uncertain" then "image_integrity_uncertain"
      end
    end

    def reasons(documents)
      documents.flat_map do |doc|
        [ reason(doc["image_integrity"]), *(Array(doc["vision_review_reasons"]) & REVIEW_REASONS) ]
      end.compact.uniq
    end
  end
end
