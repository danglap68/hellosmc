module BillVision
  class ResultComparator
    FIELDS = %w[document_type total_amount_vnd transaction_date transaction_time].freeze
    # What stops auto-approval when the two models differ: the fields that move
    # money, document type, or conflicting explicit catalog identities. A different merchant reading or lot
    # number is kept (soft_differences) but does not block: the merchant is
    # matched separately (a near match already needs a person) and the lot only
    # serves duplicate detection.
    Comparison = Data.define(:agreed, :differences, :soft_differences, :matches)

    def self.call(primary:, validator:)
      new(primary, validator).call
    end

    def initialize(primary, validator)
      @primary, @validator = primary.fetch("documents"), validator.fetch("documents")
    end

    def call
      remaining = @validator.dup
      differences, soft, matches = [], [], {}
      differences << "document_count" unless @primary.size == @validator.size
      @primary.each do |doc|
        match = remaining.find { |other| blocking_differences(doc, other).empty? }
        if match
          matches[doc.fetch("index")] = match
          soft.concat(soft_differences(doc, match))
          remaining.delete_at(remaining.index(match))
        else
          other = remaining.shift
          differences.concat(other ? blocking_differences(doc, other) : [ "document_missing" ])
          soft.concat(soft_differences(doc, other)) if other
        end
      end
      Comparison.new(agreed: differences.empty?, differences: differences.uniq, soft_differences: soft.uniq, matches: matches)
    end

    private

    def blocking_differences(left, right)
      differences = FIELDS.reject { |field| left[field] == right[field] }
      left_match = left.dig("merchant_match", "merchant_id")
      right_match = right.dig("merchant_match", "merchant_id")
      differences << "merchant_catalog_identity" if left_match && right_match && left_match != right_match
      if left["document_type"] == "transfer" && memo_key(left["transfer_memo"]) != memo_key(right["transfer_memo"])
        differences << "transfer_memo"
      end
      differences
    end

    def memo_key(value)
      return if value.blank?

      RemitterTransfers::Codes.canonical(value) || VietnameseText.normalize(value)
    end

    def soft_differences(left, right)
      differences = []
      # A conflicting identifier is material even if the names look alike.
      left_id = VietnameseText.normalize_identifier(left["terminal_or_merchant_id"])
      right_id = VietnameseText.normalize_identifier(right["terminal_or_merchant_id"])
      merchant_agrees =
        if [ left_id, right_id, left["merchant_name"], right["merchant_name"] ].all?(&:blank?)
          # Neither model found a merchant (e.g. an album total that prints only
          # the amount): not a contradiction. merchant_unreadable/merchant_missing
          # already send it to review, and nothing is confirmed by this.
          true
        elsif left_id.present? && right_id.present?
          left_id == right_id
        else
          left_name = VietnameseText.normalize(left["merchant_name"])
          right_name = VietnameseText.normalize(right["merchant_name"])
          left_name.present? && left_name == right_name
        end
      differences << "merchant_identity" if !merchant_agrees && (left["document_type"] == "settlement" || right["document_type"] == "settlement")
      # Batch number is not required, but conflicting printed lots are worth recording.
      if left["lot_number"].present? && right["lot_number"].present? && left["lot_number"] != right["lot_number"]
        differences << "lot_number"
      end
      differences
    end
  end
end
