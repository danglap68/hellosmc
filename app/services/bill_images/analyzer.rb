module BillImages
  # Runs vision extraction for one BillImage and stores both the raw provider
  # output and the normalized extraction. Never loses the raw output.
  class Analyzer
    Result = Data.define(:status, :bill_image)

    # A run claimed by another job is considered abandoned after this long.
    STALE_AFTER = 15.minutes

    # Each primary network attempt consumes a logical run. A transient retry
    # is a new run and cannot bypass the bill's lifetime OCR limit.
    def self.call(bill_image, force: false, job_id: nil, extractor: BillVision::Extractor)
      new(bill_image, force: force, job_id: job_id, extractor: extractor).call
    end

    def initialize(bill_image, force:, job_id:, extractor:)
      @bill_image = bill_image
      @force = force
      @job_id = job_id
      @extractor = extractor
    end

    def call
      skip = claim
      return exhausted if skip == :budget_exhausted
      return Result.new(status: skip, bill_image: @bill_image) if skip

      log("ocr.request")
      budget = BillVision::CallBudget.new(bill_image: @bill_image, run_id: @run_id)
      outcome = BillVision::Pipeline.call(image: @bill_image, extractor: @extractor, budget: budget)
      vision, normalized = outcome.vision, outcome.normalized

      @bill_image.with_lock do
        return Result.new(status: :in_progress, bill_image: @bill_image) unless owns_run?

        @bill_image.update!(
          raw_extraction: vision.raw,
          normalized_extraction: normalized,
          ocr_status: normalized["requires_review"] ? "needs_review" : "completed",
          ocr_provider: vision.provider,
          ocr_model: vision.model,
          ocr_confidence: normalized["min_critical_confidence"],
          analyzed_at: Time.current,
          processing_error: nil,
          metadata: @bill_image.metadata.merge("ocr_retryable" => false)
        )
      end
      log("ocr.result", ocr_status: @bill_image.ocr_status, documents: normalized["documents"].size,
                        min_critical_confidence: normalized["min_critical_confidence"])
      Result.new(status: :analyzed, bill_image: @bill_image)
    rescue BillVision::BudgetExhausted
      return Result.new(status: :in_progress, bill_image: @bill_image) unless owns_run?

      exhausted
    rescue BillVision::PermanentError => e
      unless self.class.mark_failed!(@bill_image, e, run_id: @run_id)
        return Result.new(status: :in_progress, bill_image: @bill_image)
      end
      Result.new(status: :failed, bill_image: @bill_image)
    rescue BillVision::TransientError => e
      record_transient(e)
      raise
    rescue StandardError => e
      # Storage, network or unexpected errors: retry like a transient failure,
      # so the bill ends up failed (and visible) instead of stuck in processing.
      error = BillVision::TransientError.new("OCR failed: #{e.class.name}")
      record_transient(error)
      raise error
    end

    def self.mark_failed!(bill_image, error, run_id: nil, job_id: nil, stale_before: nil)
      bill_image.with_lock do
        return false if run_id && (!bill_image.ocr_processing? || bill_image.metadata.dig("vision_pipeline", "run_id") != run_id)
        return false if job_id && (!bill_image.ocr_failed? || bill_image.metadata["ocr_claim"] != job_id)
        return false if stale_before && (!bill_image.ocr_processing? || bill_image.updated_at >= stale_before)

        bill_image.update!(ocr_status: "failed", processing_error: error.message.truncate(2000),
                           metadata: bill_image.metadata.merge("ocr_retryable" => !error.is_a?(BillVision::PermanentError)))
      end
      StructuredLog.error("ocr.failed", bill_image_id: bill_image.id, error_class: error.class.name,
                                        error: error.message.truncate(300))
      true
    end

    private

    def record_transient(error)
      @bill_image.with_lock do
        return unless owns_run?

        @bill_image.update!(ocr_status: "failed", processing_error: error.message.truncate(2000),
                            metadata: @bill_image.metadata.merge("ocr_retryable" => true))
      end
      log("ocr.transient_error", error: error.message.truncate(300))
    end

    # Returns a skip reason, or nil when this run owns the analysis.
    def claim
      @bill_image.with_lock do
        return :duplicate if @bill_image.ocr_duplicate? || @bill_image.duplicate_of_id.present?
        return :no_image unless @bill_image.image.attached?
        return :already_analyzed if !@force && (@bill_image.ocr_completed? || @bill_image.ocr_needs_review?)

        if @bill_image.ocr_processing? && @bill_image.updated_at > STALE_AFTER.ago
          return :in_progress
        end
        return :budget_exhausted if @bill_image.ocr_attempts >= AppConfig.max_ocr_attempts

        @run_id = SecureRandom.uuid
        history = Array(@bill_image.metadata["vision_history"])
        previous = @bill_image.metadata["vision_pipeline"]
        history += [ previous ] if previous.present?
        @bill_image.update!(
          ocr_status: "processing",
          processing_error: nil,
          ocr_attempts: @bill_image.ocr_attempts + 1,
          metadata: @bill_image.metadata.merge(
            "ocr_claim" => @job_id || @run_id,
            "vision_history" => history.last(BillVision::CallBudget::MAX_OCR_RUNS_PER_BILL - 1),
            "vision_pipeline" => { "run_id" => @run_id, "run_number" => @bill_image.ocr_attempts + 1,
                                   "calls" => { "primary" => 0, "validator" => 0 } }
          )
        )
      end
      nil
    end

    def owns_run?
      @bill_image.ocr_processing? && @run_id.present? && @bill_image.metadata.dig("vision_pipeline", "run_id") == @run_id
    end

    def exhausted
      @bill_image.with_lock do
        return Result.new(status: :in_progress, bill_image: @bill_image) if @run_id && !owns_run?
        return Result.new(status: :in_progress, bill_image: @bill_image) if !@run_id && @bill_image.ocr_runs_remaining?

        normalized = @bill_image.normalized_extraction.presence ||
          BillVision::Normalizer.call({}, provider: AppConfig.vision_provider, model: AppConfig.primary_vision_model)
        normalized = normalized.deep_dup
        normalized["requires_review"] = true
        normalized["documents"].each do |doc|
          doc["requires_review"] = true
          doc["vision_review_reasons"] = Array(doc["vision_review_reasons"]) | [ "validation_budget_exhausted" ]
        end
        @bill_image.update!(normalized_extraction: normalized, ocr_status: "needs_review",
                            metadata: @bill_image.metadata.merge("ocr_retryable" => false, "ocr_budget_exhausted" => true))
      end
      log("ocr.budget_exhausted")
      Result.new(status: :analyzed, bill_image: @bill_image)
    end

    def log(event, **fields)
      StructuredLog.info(event, bill_image_id: @bill_image.id, provider: AppConfig.vision_provider,
                                telegram_message_id: @bill_image.telegram_message&.telegram_message_id, **fields)
    end
  end
end
