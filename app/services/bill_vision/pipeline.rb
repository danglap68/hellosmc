module BillVision
  # Finite factual extraction: primary -> optional independent validator -> END.
  # The primary facts are never replaced by a disagreeing validator.
  class Pipeline
    Outcome = Data.define(:vision, :normalized, :metadata)

    def self.call(image:, extractor: Extractor, budget: CallBudget.new)
      new(image, extractor, budget).call
    end

    def initialize(image, extractor, budget)
      @bill_image = image if image.is_a?(BillImage)
      @image = @bill_image ? Image.from_bill_image(image) : image
      @extractor, @budget = extractor, budget
      @review_reasons = []
    end

    def call
      primary = extract(:primary)
      normalized = normalize(primary)
      @budget.record!("primary" => snapshot(primary, normalized))
      decision = ValidationPolicy.call(normalized: normalized, bill_image: @bill_image)
      @budget.record!("visual_validation_reasons" => decision.visual_validation_reasons,
                      "deterministic_business_review_reasons" => decision.deterministic_business_review_reasons)

      if primary.provider == "openai" && AppConfig.vision_validation_enabled? &&
          AppConfig.vision_validation_mode == "risk_based" && decision.validate?
        validate(primary, normalized, decision.visual_validation_reasons)
      else
        @budget.record!("validation_result" => "skipped", "validation_reason" => [], "validation_triggered" => false)
        log("ocr.validation.skipped", reasons: decision.visual_validation_reasons,
                                     business_reasons: decision.deterministic_business_review_reasons)
        outcome(primary, normalized)
      end
    rescue InvalidExtraction => e
      # Malformed output may be independently reread once, but it cannot be
      # auto-approved because the primary supplied no comparable facts.
      primary = Result.new(provider: "openai", model: e.model, data: {}, raw: e.raw)
      normalized = Normalizer.call({}, provider: primary.provider, model: primary.model)
      @budget.record!("primary" => snapshot(primary, normalized).merge("error" => e.reason))
      @review_reasons << e.reason
      if e.reason == "malformed_primary_extraction" && AppConfig.vision_validation_enabled?
        validate(primary, normalized, [ e.reason ], comparable: false)
      else
        @budget.record!("validation_result" => "unresolved", "validation_reason" => [ e.reason ], "validation_triggered" => false)
        outcome(primary, normalized)
      end
    rescue BudgetExhausted
      log("ocr.budget_exhausted")
      raise
    end

    private

    def extract(stage)
      @budget.consume!(stage)
      model = stage == :primary ? AppConfig.primary_vision_model : AppConfig.validator_vision_model
      event = stage == :primary ? "ocr.primary" : "ocr.validation"
      log("#{event}.request", request_type: stage, model: model)
      vision =
        if stage == :primary
          @extractor.call(image: @image)
        else
          Extractor.call(image: @image, provider: OpenaiProvider.new(model: model, max_output_tokens: CallBudget::MAX_OUTPUT_TOKENS))
        end
      log("#{event}.result", request_type: stage, model: vision.model, **usage(vision.raw))
      vision
    rescue InvalidExtraction => e
      log("#{event}.result", request_type: stage, model: e.model, error: e.reason, **usage(e.raw))
      raise
    rescue Error => e
      @budget.record!(stage.to_s => { "provider" => AppConfig.vision_provider, "model" => model,
                                     "error" => e.class.name, "usage" => {} }) unless e.is_a?(BudgetExhausted)
      log("#{event}.result", request_type: stage, model: model, error_class: e.class.name) unless e.is_a?(BudgetExhausted)
      raise
    end

    def validate(primary, normalized, reasons, comparable: true)
      @budget.record!("validation_triggered" => true, "validation_reason" => reasons)
      validator = extract(:validator)
      validator_normalized = normalize(validator)
      @budget.record!("validator" => snapshot(validator, validator_normalized))
      comparison = ResultComparator.call(primary: normalized, validator: validator_normalized)
      if comparable && comparison.agreed
        normalized = confirm_fields(normalized.deep_dup, comparison.matches)
        result = normalized["requires_review"] ? "unresolved" : "agreed"
      elsif comparable
        @review_reasons << "model_disagreement"
        result = "disagreed"
        log("ocr.model_disagreement", fields: comparison.differences)
      else
        result = "unresolved"
      end
      @budget.record!("validation_result" => result, "disagreement_fields" => comparison.differences)
      outcome(primary, normalized)
    rescue BudgetExhausted
      @review_reasons << "validation_budget_exhausted"
      log("ocr.budget_exhausted")
      @budget.record!("validation_result" => "budget_exhausted")
      outcome(primary, normalized)
    rescue Error => e
      if e.is_a?(InvalidExtraction)
        vision = Result.new(provider: "openai", model: e.model, data: {}, raw: e.raw)
        @budget.record!("validator" => snapshot(vision, nil).merge("error" => e.reason))
      end
      @review_reasons << "validator_failed"
      @budget.record!("validation_result" => "validator_failed")
      outcome(primary, normalized)
    end

    def normalize(vision)
      if vision.provider == "openai" && !OutputSchema.valid?(vision.data)
        raise InvalidExtraction.new("openai answer does not match the extraction schema", raw: vision.raw, model: vision.model)
      end
      Normalizer.call(vision.data, provider: vision.provider, model: vision.model)
    rescue ArgumentError, TypeError, NoMethodError
      raise InvalidExtraction.new("OCR normalization failed", raw: vision.raw, model: vision.model)
    end

    def confirm_fields(normalized, matches)
      normalized["documents"].each do |doc|
        other = matches.fetch(doc.fetch("index"))
        confirmed = Prompt::FIELDS.select do |field|
          doc[field].present? && doc[field] == other[field] &&
            other.dig("confidence", field).to_f >= AppConfig.ocr_auto_approve_threshold
        end
        # Equivalent diacritics/formatting still identify the same merchant.
        if VietnameseText.normalize(doc["merchant_name"]).present? &&
            VietnameseText.normalize(doc["merchant_name"]) == VietnameseText.normalize(other["merchant_name"]) &&
            other.dig("confidence", "merchant_name").to_f >= AppConfig.ocr_auto_approve_threshold
          confirmed |= [ "merchant_name" ]
        end
        doc["validation_confirmed_fields"] = confirmed
        remaining = doc.fetch("low_confidence_fields") - confirmed
        remaining -= [ "merchant_name" ] if confirmed.include?("terminal_or_merchant_id")
        doc["requires_review"] = doc["document_type"] == "unknown" || remaining.any?
      end
      normalized["requires_review"] = normalized["documents_truncated"].to_i.positive? ||
        normalized["documents"].any? { |doc| doc["requires_review"] }
      normalized
    end

    def outcome(primary, normalized)
      if @review_reasons.any?
        normalized = normalized.deep_dup
        normalized["requires_review"] = true
        normalized["documents"].each do |doc|
          doc["requires_review"] = true
          doc["vision_review_reasons"] = @review_reasons.uniq
        end
      end
      @budget.record!("review_reasons" => @review_reasons.uniq)
      Outcome.new(vision: primary, normalized: normalized, metadata: @budget.snapshot)
    end

    def snapshot(vision, normalized)
      { "provider" => vision.provider, "model" => vision.model, "raw_output" => vision.raw,
        "normalized_output" => normalized, "usage" => usage(vision.raw).stringify_keys }
    end

    def usage(raw)
      values = raw.to_h["usage"].to_h
      { input_tokens: values["prompt_tokens"], cached_input_tokens: values.dig("prompt_tokens_details", "cached_tokens"),
        output_tokens: values["completion_tokens"], total_tokens: values["total_tokens"] }.compact
    end

    def log(event, **fields)
      StructuredLog.info(event, bill_image_id: @bill_image&.id, **fields)
    end
  end
end
