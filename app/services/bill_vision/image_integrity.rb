module BillVision
  # Advisory screening of incoming receipt images, never proof of authenticity.
  module ImageIntegrity
    STATUSES = %w[no_visible_signs suspicious uncertain].freeze
    REVIEW_REASONS = %w[image_tampering_suspected image_integrity_uncertain].freeze
    SCHEMA = {
      type: %w[object null], additionalProperties: false, required: %w[status evidence risk_score],
      properties: {
        status: { type: "string", enum: STATUSES },
        evidence: { type: "array", maxItems: 2, items: { type: "string", maxLength: 160 } },
        risk_score: { type: %w[number null], minimum: 0, maximum: 1 }
      }
    }.freeze

    module_function

    def valid?(assessment)
      return false unless assessment.is_a?(Hash) &&
        (assessment.keys - [ "risk_score" ]).sort == %w[evidence status]
      return false unless STATUSES.include?(assessment["status"])
      score = assessment["risk_score"]
      return false unless score.nil? || (score.is_a?(Numeric) && score.finite? && score.between?(0, 1))

      evidence = assessment["evidence"]
      evidence.is_a?(Array) && evidence.size <= 2 &&
        evidence.all? { |item| item.is_a?(String) && item.strip.present? && item.length <= 160 } &&
        (assessment["status"] != "suspicious" || evidence.any?)
    end

    def applicable?(document)
      document["document_type"] != "transfer" && document["downgraded_from"] != "transfer"
    end

    def blocking_reasons(reasons)
      Array(reasons) - REVIEW_REASONS
    end

    # Keep the strongest observed assessment across independent reads/retries.
    # An old assessment without a score must not inherit a clean read's score.
    def combine(assessments)
      candidates = assessments.compact.select { |item| item.is_a?(Hash) }
      return if candidates.empty?

      priority = { "not_assessed" => 0, "no_visible_signs" => 1, "uncertain" => 2, "suspicious" => 3 }
      strongest = candidates.max_by { |item| priority.fetch(item["status"], 0) }["status"]
      selected = candidates.select { |item| item["status"] == strongest }
      scores = selected.filter_map { |item| item["risk_score"] if valid?(item) }
      { "status" => strongest, "risk_score" => scores.max,
        "evidence" => selected.flat_map { |item| Array(item["evidence"]) }.uniq.first(2) }
    end
  end
end
