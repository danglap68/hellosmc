module BillVision
  # Verify the same strict contract locally, even if an upstream response
  # claims to have used structured output. Do not normalize schema drift away.
  module OutputSchema
    module_function

    def valid?(data, require_integrity: false)
      return false unless data.is_a?(Hash) && data.keys.sort == %w[documents notes]
      return false unless data["notes"].nil? || data["notes"].is_a?(String)
      return false unless data["documents"].is_a?(Array)

      data["documents"].all? { |document| valid_document?(document, require_integrity: require_integrity) }
    end

    def valid_document?(doc, require_integrity: false)
      return false unless doc.is_a?(Hash)
      return false unless (doc.keys - [ Prompt::RECIPIENT_FIELD, Prompt::BANK_FIELD, Prompt::TRANSFER_REFERENCE_FIELD, "merchant_match", "image_integrity" ] - Prompt::FLAGS - Prompt::TRANSFER_MEMO_FIELDS).sort == (Prompt::FIELDS + [ "confidence" ]).sort
      return false if (require_integrity || doc.key?("image_integrity")) && !ImageIntegrity.valid?(doc["image_integrity"])
      return false unless valid_merchant_match?(doc["merchant_match"])
      return false unless doc[Prompt::RECIPIENT_FIELD].nil? || doc[Prompt::RECIPIENT_FIELD].is_a?(String)
      return false unless doc[Prompt::BANK_FIELD].nil? || doc[Prompt::BANK_FIELD].is_a?(String)
      return false unless doc["transfer_memo"].nil? || doc["transfer_memo"].is_a?(String)
      return false unless doc[Prompt::TRANSFER_REFERENCE_FIELD].nil? || doc[Prompt::TRANSFER_REFERENCE_FIELD].is_a?(String)
      if doc.key?("transfer_memo_confidence")
        score = doc["transfer_memo_confidence"]
        return false unless score.is_a?(Numeric) && score.finite? && score.between?(0, 1)
      end
      return false unless Prompt::FLAGS.all? { |flag| [ nil, true, false ].include?(doc[flag]) }
      return false unless Prompt::DOCUMENT_TYPES.include?(doc["document_type"])
      return false unless doc["total_amount_vnd"].nil? || doc["total_amount_vnd"].is_a?(Integer)
      return false unless (Prompt::FIELDS - %w[document_type total_amount_vnd]).all? { |field| doc[field].nil? || doc[field].is_a?(String) }

      confidence = doc["confidence"]
      confidence.is_a?(Hash) && confidence.keys.sort == Prompt::FIELDS.sort &&
        confidence.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.between?(0, 1) }
    end

    # Optional locally for stored extractions made before catalog matching existed.
    def valid_merchant_match?(match)
      return true if match.nil?
      return false unless match.is_a?(Hash) && match.keys.sort == %w[confidence merchant_id]

      id, confidence = match.values_at("merchant_id", "confidence")
      id.is_a?(Integer) && id.positive? && confidence.is_a?(Numeric) &&
        confidence.finite? && confidence.between?(0, 1)
    end
  end
end
