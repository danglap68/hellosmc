module BillVision
  # Turns provider output into the normalized extraction stored on BillImage:
  # typed values, a business-timezone timestamp, per-field confidence and the
  # list of critical fields that are below the auto-approve threshold.
  #
  # It validates and cleans facts; it never invents or corrects them.
  class Normalizer
    SCHEMA_VERSION = 4
    MAX_DOCUMENTS = 20
    # The merchant counts as identified when either its name or its MID/TID is read confidently.
    CRITICAL_FIELDS = %w[document_type total_amount_vnd merchant_name transaction_date transaction_time].freeze
    # A transfer only needs its amount and date to be verifiable; merchant/time are not required.
    CRITICAL_FIELDS_BY_TYPE = {
      "settlement" => CRITICAL_FIELDS,
      "transfer" => %w[document_type total_amount_vnd transaction_date],
      "child_receipt" => %w[document_type],
      "unknown" => %w[document_type]
    }.freeze

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
        "image_integrity" => ImageIntegrity.combine(normalized.filter_map { |doc| doc["image_integrity"] }),
        "documents_truncated" => truncated,
        "min_critical_confidence" => normalized.map { |doc| doc["critical_confidence"] }.min,
        # Settlements beyond MAX_DOCUMENTS would be silently lost: a human must look.
        "requires_review" => truncated.positive? || normalized.any? { |doc| doc["requires_review"] }
      }
    end

    private

    def normalize_document(doc, index)
      document_type = Prompt::DOCUMENT_TYPES.include?(doc["document_type"]) ? doc["document_type"] : "unknown"
      downgraded_from = document_type if transfer_not_confirmed?(document_type, doc)
      document_type = "unknown" if downgraded_from
      document_type = "child_receipt" if transfer_misread?(document_type, doc)
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
      recipient_name = document_type == "transfer" ? clean_string(doc[Prompt::RECIPIENT_FIELD]) : nil
      transfer_memo = document_type == "transfer" ? clean_string(doc["transfer_memo"]) : nil

      confidence = Prompt::FIELDS.index_with do |field|
        # A missing value cannot be trusted, whatever the model claimed.
        values[field].nil? ? 0.0 : clamp(doc.dig("confidence", field))
      end

      low_fields = low_confidence_fields(document_type, confidence)
      integrity = if document_type != "transfer" && downgraded_from != "transfer"
        if ImageIntegrity.valid?(doc["image_integrity"])
          doc["image_integrity"].deep_dup
        else
          { "status" => "not_assessed", "evidence" => [] }
        end
      end
      review_reasons = []
      if downgraded_from && flag(doc, "shows_qr_code") == true &&
          (flag(doc, "shows_success_message") == true || booked_transfer?(doc))
        review_reasons << "transfer_confirmation_conflict"
      end
      values.merge(
        "index" => index,
        "recipient_name" => recipient_name,
        "transfer_memo" => transfer_memo,
        "transfer_memo_confidence" => transfer_memo ? clamp(doc["transfer_memo_confidence"]) : 0.0,
        "bank_transaction_reference" => (clean_string(doc[Prompt::TRANSFER_REFERENCE_FIELD]) if document_type == "transfer"),
        "bill_bank_name" => clean_string(doc[Prompt::BANK_FIELD]),
        "shows_success_message" => flag(doc, "shows_success_message"),
        "shows_booked_transfer" => flag(doc, "shows_booked_transfer"),
        "shows_qr_code" => flag(doc, "shows_qr_code"),
        "shows_smart_pos" => flag(doc, Prompt::SMART_POS_FLAG),
        "downgraded_from" => downgraded_from,
        "transaction_at" => (date && time) ? Time.zone.local(date.year, date.month, date.day, *time).iso8601 : nil,
        "merchant_name_normalized" => VietnameseText.normalize(merchant_name).presence,
        "merchant_match" => (doc["merchant_match"].deep_dup if document_type.in?(%w[settlement child_receipt]) &&
                              OutputSchema.valid_merchant_match?(doc["merchant_match"])),
        "confidence" => confidence,
        "critical_confidence" => critical_fields(document_type).map { |field| critical_value(confidence, field) }.min,
        "low_confidence_fields" => low_fields,
        "image_integrity" => integrity,
        "requires_review" => requires_review?(document_type, low_fields)
      ).tap do |normalized|
        normalized["vision_review_reasons"] = review_reasons if review_reasons.any?
      end
    end

    # A "transfer" that shows a QR code is a request to be paid, not money sent;
    # one without a success banner or a verifiable booked history entry is
    # not a confirmation. Either way the
    # photo becomes "unknown". Conflicting completion evidence needs review,
    # rather than being silently skipped. A run that
    # does not report the flags (older output) keeps its type.
    def transfer_not_confirmed?(document_type, doc)
      document_type == "transfer" && (flag(doc, "shows_qr_code") == true ||
        (flag(doc, "shows_success_message") == false && !booked_transfer?(doc)))
    end

    def booked_transfer?(doc)
      flag(doc, "shows_booked_transfer") == true &&
        clean_string(doc[Prompt::TRANSFER_REFERENCE_FIELD]).present? &&
        parse_amount(doc["total_amount_vnd"]).to_i.positive? &&
        parse_date(doc["transaction_date"]).present? && parse_time(doc["transaction_time"]).present? &&
        clean_string(doc[Prompt::RECIPIENT_FIELD]).present?
    end

    def flag(doc, name)
      doc[name] if [ true, false ].include?(doc[name])
    end

    # A bank transfer never prints a POS batch/lot or terminal number. When the
    # model labels a document "transfer" but still read those fields, it actually
    # read a card-sale slip (child_receipt) — e.g. a SALE screen with the generic
    # "GIAO DỊCH THÀNH CÔNG" banner.
    def transfer_misread?(document_type, doc)
      document_type == "transfer" &&
        (clean_string(doc["lot_number"]).present? || clean_string(doc["terminal_or_merchant_id"]).present?)
    end

    def critical_fields(document_type)
      CRITICAL_FIELDS_BY_TYPE.fetch(document_type, %w[document_type])
    end

    def low_confidence_fields(document_type, confidence)
      critical_fields(document_type).select do |field|
        BigDecimal(critical_value(confidence, field).to_s) < AppConfig.ocr_auto_approve_threshold
      end
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
