module BillVision
  # Verify the same strict contract locally, even if an upstream response
  # claims to have used structured output. Do not normalize schema drift away.
  module OutputSchema
    module_function

    def valid?(data)
      return false unless data.is_a?(Hash) && data.keys.sort == %w[documents notes]
      return false unless data["notes"].nil? || data["notes"].is_a?(String)
      return false unless data["documents"].is_a?(Array)

      data["documents"].all? { |document| valid_document?(document) }
    end

    def valid_document?(doc)
      return false unless doc.is_a?(Hash) && doc.keys.sort == (Prompt::FIELDS + [ "confidence" ]).sort
      return false unless Prompt::DOCUMENT_TYPES.include?(doc["document_type"])
      return false unless doc["total_amount_vnd"].nil? || doc["total_amount_vnd"].is_a?(Integer)
      return false unless (Prompt::FIELDS - %w[document_type total_amount_vnd]).all? { |field| doc[field].nil? || doc[field].is_a?(String) }

      confidence = doc["confidence"]
      confidence.is_a?(Hash) && confidence.keys.sort == Prompt::FIELDS.sort &&
        confidence.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.between?(0, 1) }
    end
  end
end
