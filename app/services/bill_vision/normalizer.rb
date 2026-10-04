module BillVision
  # Turns provider output into the normalized extraction stored on BillImage:
  # typed values, a business-timezone timestamp, per-field confidence and the
  # list of critical fields that are below the auto-approve threshold.
  #
  # It validates and cleans facts; it never invents or corrects them.
  class Normalizer
    SCHEMA_VERSION = 1
    MAX_DOCUMENTS = 20
    # The merchant counts as identified when either its name or its MID/TID is read confidently.
    CRITICAL_FIELDS = %w[document_type total_amount_vnd merchant_name transaction_date transaction_time].freeze

    def self.call(data, provider:, model:)
      new(data, provider: provider, model: model).call
    end

    def initialize(data, provider:, model:)
      @data = data.to_h.deep_stringify_keys
      @provider = provider
      @model = model
    end

    def call
      all_documents = Array(@data["documents"]).select { |doc| doc.is_a?(Hash) }
      documents = all_documents.first(MAX_DOCUMENTS)
      truncated = all_documents.size - documents.size
      # Nothing recognised is still something a human has to look at.
      documents = [ {} ] if documents.empty?
      normalized = documents.each_with_index.map { |doc, index| normalize_document(doc, index) }

      {
        "schema_version" => SCHEMA_VERSION,
        "provider" => @provider,
        "model" => @model,
        "notes" => @data["notes"].presence,
        "documents" => normalized,
        "documents_truncated" => truncated,
        "min_critical_confidence" => normalized.map { |doc| doc["critical_confidence"] }.min,
        # Settlements beyond MAX_DOCUMENTS would be silently lost: a human must look.
        "requires_review" => truncated.positive? || normalized.any? { |doc| doc["requires_review"] }
      }
    end

    private

    def normalize_document(doc, index)
      document_type = Prompt::DOCUMENT_TYPES.include?(doc["document_type"]) ? doc["document_type"] : "unknown"
      amount = parse_amount(doc["total_amount_vnd"])
      date = parse_date(doc["transaction_date"])
      time = parse_time(doc["transaction_time"])
      merchant_name = clean_string(doc["merchant_name"])
      values = {
        "document_type" => document_type,
        "total_amount_vnd" => amount,
        "lot_number" => clean_string(doc["lot_number"]),
        "transaction_date" => date&.iso8601,
        "transaction_time" => time && format("%02d:%02d:%02d", *time),
        "merchant_name" => merchant_name,
        "terminal_or_merchant_id" => clean_string(doc["terminal_or_merchant_id"])
      }

      confidence = Prompt::FIELDS.index_with do |field|
        # A missing value cannot be trusted, whatever the model claimed.
        values[field].nil? ? 0.0 : clamp(doc.dig("confidence", field))
      end

      low_fields = low_confidence_fields(document_type, confidence)
      values.merge(
        "index" => index,
        "transaction_at" => (date && time) ? Time.zone.local(date.year, date.month, date.day, *time).iso8601 : nil,
        "merchant_name_normalized" => VietnameseText.normalize(merchant_name).presence,
        "confidence" => confidence,
        "critical_confidence" => CRITICAL_FIELDS.map { |field| critical_value(confidence, field) }.min,
        "low_confidence_fields" => low_fields,
        "requires_review" => requires_review?(document_type, low_fields)
      )
    end

    def low_confidence_fields(document_type, confidence)
      fields = document_type == "settlement" ? CRITICAL_FIELDS : [ "document_type" ]
      fields.select { |field| BigDecimal(critical_value(confidence, field).to_s) < AppConfig.ocr_auto_approve_threshold }
    end

    def critical_value(confidence, field)
      return confidence[field] unless field == "merchant_name"

      [ confidence["merchant_name"], confidence["terminal_or_merchant_id"] ].max
    end

    def requires_review?(document_type, low_fields)
      document_type == "unknown" || low_fields.any?
    end

    def clamp(value)
      number = Float(value, exception: false)
      return 0.0 if number.nil? || number.nan?

      number.clamp(0.0, 1.0).round(4)
    end

    # Integer VND. Accepts "11.445.000" or 11445000(.0); anything else is nil.
    def parse_amount(value)
      amount =
        case value
        when Integer then value
        when Float then value == value.floor ? value.to_i : nil
        when String then value.strip.match?(/\A\d{1,3}([.,\s]?\d{3})*\z/) ? value.gsub(/\D/, "").to_i : nil
        end
      amount&.positive? ? amount : nil
    end

    def parse_date(value)
      text = value.to_s.strip
      return nil if text.empty?

      date =
        if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          Date.strptime(text, "%Y-%m-%d")
        elsif text.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z})
          Date.strptime(text, "%d/%m/%Y")
        end
      date
    rescue Date::Error
      nil
    end

    def parse_time(value)
      match = value.to_s.strip.match(/\A(\d{1,2}):(\d{2})(?::(\d{2}))?\z/)
      return nil unless match

      hour, minute, second = match[1].to_i, match[2].to_i, match[3].to_i
      return nil unless hour < 24 && minute < 60 && second < 60

      [ hour, minute, second ]
    end

    def clean_string(value)
      return nil unless value.is_a?(String) || value.is_a?(Numeric)

      value.to_s.squish.presence
    end
  end
end
