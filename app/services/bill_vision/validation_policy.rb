module BillVision
  # Reread an image only when it can improve factual extraction. Configuration
  # problems go straight to human review, even when OCR is also uncertain.
  class ValidationPolicy
    Decision = Data.define(:visual_validation_reasons, :deterministic_business_review_reasons) do
      def validate?
        visual_validation_reasons.any? && deterministic_business_review_reasons.empty?
      end
    end

    CONFIGURATION_REASONS = %w[dealer_unmapped dealer_inactive fee_rule_not_found fee_rule_ambiguous
                               merchant_dealer_mismatch merchant_not_found card_type_conflict card_type_unknown].freeze

    def self.call(normalized:, bill_image: nil)
      new(normalized, bill_image).call
    end

    def initialize(normalized, bill_image)
      @normalized, @bill_image = normalized, bill_image
    end

    def call
      visual, business = [], []
      documents = @normalized.fetch("documents")
      visual << "multiple_settlement_documents" if documents.count { |doc| doc["document_type"] == "settlement" } > 1
      visual << "too_many_documents" if @normalized["documents_truncated"].to_i.positive?
      documents.each do |doc|
        next if doc["document_type"] == "child_receipt" && !doc["requires_review"]

        visual << "document_type_uncertain" if doc["document_type"] == "unknown"
        visual << "amount_unreadable" if doc["document_type"] == "settlement" && doc["total_amount_vnd"].nil?
        visual << "transaction_date_unreadable" if doc["document_type"] == "settlement" && doc["transaction_date"].nil?
        visual << "transaction_time_unreadable" if doc["document_type"] == "settlement" && doc["transaction_time"].nil?
        if doc["document_type"] == "settlement" && doc["merchant_name"].blank? && doc["terminal_or_merchant_id"].blank?
          visual << "merchant_unreadable"
        end
        # Confidence is a supporting signal, not calibrated probability.
        # A soft score such as .91 alone does not buy another model call.
        Array(doc["low_confidence_fields"]).each do |field|
          score = field == "merchant_name" ? [ doc.dig("confidence", field), doc.dig("confidence", "terminal_or_merchant_id") ].max : doc.dig("confidence", field)
          if score.to_f < AppConfig.ocr_review_threshold
            prefix = { "total_amount_vnd" => "amount", "merchant_name" => "merchant" }.fetch(field, field)
            visual << "#{prefix}_unreadable"
          end
        end
        next unless @bill_image

        evaluation = Transactions::Evaluator.call(document: doc, bill_image: @bill_image)
        business.concat(evaluation.review_reasons & CONFIGURATION_REASONS)
        prospective = Transaction.new(evaluation.attributes.merge(bill_image: @bill_image))
        business << "possible_duplicate" if Transactions::DuplicateDetector.call(prospective).possible_duplicate?
        visual << "transaction_date_out_of_range" if evaluation.review_reasons.include?("transaction_date_out_of_range")
        visual << "merchant_fuzzy_match" if evaluation.review_reasons.include?("merchant_fuzzy_match")
        if evaluation.review_reasons.include?("merchant_ambiguous")
          # Exact alias/name collisions are a configuration issue; ambiguous
          # fuzzy suggestions can instead be caused by unreadable text.
          target = evaluation.source_data.dig("merchant_resolution", "score") ? visual : business
          target << "merchant_ambiguous"
        end
      end
      Decision.new(visual_validation_reasons: visual.uniq, deterministic_business_review_reasons: business.uniq)
    end
  end
end
