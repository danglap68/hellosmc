module BillVision
  class ResultComparator
    FIELDS = %w[document_type total_amount_vnd transaction_date transaction_time].freeze
    Comparison = Data.define(:agreed, :differences, :matches)

    def self.call(primary:, validator:)
      new(primary, validator).call
    end

    def initialize(primary, validator)
      @primary, @validator = primary.fetch("documents"), validator.fetch("documents")
    end

    def call
      remaining = @validator.dup
      differences, matches = [], {}
      differences << "document_count" unless @primary.size == @validator.size
      @primary.each do |doc|
        match = remaining.find { |other| differences_for(doc, other).empty? }
        if match
          matches[doc.fetch("index")] = match
          remaining.delete_at(remaining.index(match))
        else
          other = remaining.shift
          differences.concat(other ? differences_for(doc, other) : [ "document_missing" ])
        end
      end
      Comparison.new(agreed: differences.empty?, differences: differences.uniq, matches: matches)
    end

    private

    def differences_for(left, right)
      differences = FIELDS.reject { |field| left[field] == right[field] }
      # A conflicting identifier is material even if the names look alike.
      left_id = VietnameseText.normalize_identifier(left["terminal_or_merchant_id"])
      right_id = VietnameseText.normalize_identifier(right["terminal_or_merchant_id"])
      merchant_agrees =
        if left_id.present? && right_id.present?
          left_id == right_id
        else
          left_name = VietnameseText.normalize(left["merchant_name"])
          right_name = VietnameseText.normalize(right["merchant_name"])
          left_name == right_name
        end
      differences << "merchant_identity" unless merchant_agrees
      # Batch number is not required, but conflicting printed lots matter.
      if left["lot_number"].present? && right["lot_number"].present? && left["lot_number"] != right["lot_number"]
        differences << "lot_number"
      end
      differences
    end
  end
end
